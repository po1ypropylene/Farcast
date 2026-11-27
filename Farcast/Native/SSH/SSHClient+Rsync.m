#import "SSHClientInternal.h"
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

static NSString *shellWord(NSString *word) {
    return [NSString stringWithFormat:@"'%@'", [word stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static void closeFD(int *fd) {
    if (*fd >= 0)
        close(*fd);
    *fd = -1;
}

// LC_ALL=C makes rsync escape nonprintable bytes (including newlines) in
// itemized names. Recover the original UTF-8 before using a name in a file list.
static NSString *itemizedName(NSString *text) {
    NSData *input = [text dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = input.bytes;
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger i = 0; i < input.length; i++) {
        uint8_t byte = bytes[i];
        if (byte == 92 && i + 4 < input.length && bytes[i + 1] == '#' && bytes[i + 2] >= '0' && bytes[i + 2] <= '3' &&
            bytes[i + 3] >= '0' && bytes[i + 3] <= '7' && bytes[i + 4] >= '0' && bytes[i + 4] <= '7') {
            byte = (bytes[i + 2] - '0') * 64 + (bytes[i + 3] - '0') * 8 + bytes[i + 4] - '0';
            i += 4;
        }
        if (!byte)
            return nil;
        [data appendBytes:&byte length:1];
    }
    NSString *name = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return name.length && !name.isAbsolutePath && ![name.pathComponents containsObject:@".."] ? name : nil;
}

static BOOL nonblocking(int fd) { return fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0; }

// The peer is an inherited socketpair, accessible only to this spawned process
// tree. Consume one message and check both the argument shape and descriptors.
static NSString *receiveStreams(int socket, int streams[2], NSString *binary, NSString *path) {
    char bytes[16384];
    union {
        struct cmsghdr align;
        char data[CMSG_SPACE(sizeof(int) * 2)];
    } control = {0};
    struct iovec vector = {bytes, sizeof(bytes)};
    struct msghdr msg = {
        .msg_iov = &vector, .msg_iovlen = 1, .msg_control = control.data, .msg_controllen = sizeof(control.data)};
    ssize_t count = recvmsg(socket, &msg, 0);
    struct cmsghdr *header = CMSG_FIRSTHDR(&msg);
    if (count <= 0 || !header || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
        header->cmsg_len != CMSG_LEN(2 * sizeof(int)))
        return nil;
    memcpy(streams, CMSG_DATA(header), 2 * sizeof(int));
    if (msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC) || bytes[count - 1] != 0)
        return nil;
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (size_t offset = 0; offset < (size_t)count;) {
        NSString *arg = [NSString stringWithUTF8String:bytes + offset];
        if (!arg || args.count >= 128)
            return nil;
        [args addObject:arg];
        offset += strlen(bytes + offset) + 1;
    }
    if (args.count < 3 || ![args.firstObject isEqual:@"--server"] || ![args[args.count - 2] isEqual:@"."])
        return nil;
    args[args.count - 1] = path;
    NSMutableArray *words = [NSMutableArray arrayWithObject:shellWord(binary)];
    for (NSString *arg in args)
        [words addObject:shellWord(arg)];
    return [words componentsJoinedByString:@" "];
}

@implementation FCSSHClient (RsyncWorker)
- (void)probeRsync:(NSString *)overridePath requestID:(NSString *)requestID {
    [self enqueueFileRequest:@{@"id" : requestID, @"kind" : @"probeRsync", @"override" : overridePath}];
}
- (void)transferRsync:(NSDictionary *)configuration requestID:(NSString *)requestID {
    [self enqueueFileRequest:@{@"id" : requestID, @"kind" : @"rsync", @"config" : configuration}];
}
- (LIBSSH2_CHANNEL *)rsyncChannel:(NSString *)command {
    double deadline = monotonicTime() + 15;
    if (![self drainForwardOpenUntil:deadline])
        return NULL;
    _channelOpenBusy = YES;
    LIBSSH2_CHANNEL *channel;
    do {
        channel = libssh2_channel_open_session(_workerSession);
    } while (!channel && libssh2_session_last_errno(_workerSession) == LIBSSH2_ERROR_EAGAIN &&
             [self waitForFileUntil:deadline]);
    _channelOpenBusy = NO;
    if (channel) {
        libssh2_channel_handle_extended_data2(channel, LIBSSH2_CHANNEL_EXTENDED_DATA_IGNORE);
        int rc;
        do {
            rc = libssh2_channel_exec(channel, command.UTF8String);
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
        if (rc) {
            [self releaseRsyncChannel:channel];
            return NULL;
        }
    }
    return channel;
}
- (void)releaseRsyncChannel:(LIBSSH2_CHANNEL *)channel {
    double deadline = monotonicTime() + 5;
    while (libssh2_channel_free(channel) == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]) {
    }
}
- (NSDictionary *)rsyncProbe:(NSString *)override {
    NSString *command = [NSString
        stringWithFormat:
            @"LC_ALL=C; export LC_ALL; { printf '%%s\\n' %@ /usr/local/bin/rsync /opt/homebrew/bin/rsync "
            @"/opt/bin/rsync /opt/local/bin/rsync \"$HOME/bin/rsync\" \"$HOME/.local/bin/rsync\" /usr/bin/rsync; "
            @"(command -v -a rsync || command -v rsync) 2>/dev/null; (IFS=:; for d in $PATH; do printf '%%s\\n' "
            @"\"$d/rsync\"; done); } | "
            @"while IFS= read -r p; do case \"$p\" in /*) ;; *) continue;; esac; [ -f \"$p\" ] && [ -x \"$p\" ] || "
            @"continue; "
            @"real=$(realpath \"$p\" 2>/dev/null) || real=$p; case \"$seen\" in *\"|$real|\"*) continue;; esac; "
            @"seen=\"$seen|$real|\"; "
            @"printf '\\000%%s\\000' \"$p\"; \"$p\" --version 2>/dev/null | head -n 2; done",
            shellWord(override)];
    LIBSSH2_CHANNEL *channel = [self rsyncChannel:[@"sh -c " stringByAppendingString:shellWord(command)]];
    if (!channel)
        return @{};
    NSMutableData *data = [NSMutableData data];
    double deadline = monotonicTime() + 3;
    while (!atomic_load(&_stopped) && monotonicTime() < deadline && data.length < 65536) {
        char bytes[4096];
        ssize_t n = libssh2_channel_read(channel, bytes, sizeof(bytes));
        if (n > 0)
            [data appendBytes:bytes length:n];
        else if (libssh2_channel_eof(channel) || (n < 0 && n != LIBSSH2_ERROR_EAGAIN))
            break;
        else {
            if (![self serviceInteractive])
                break;
            [self waitForServiceEvents:POLLIN timeout:10];
        }
    }
    [self releaseRsyncChannel:channel];
    return @{@"versions" : data};
}
- (NSDictionary *)runRsync:(NSDictionary *)cfg
                 requestID:(NSString *)requestID
                    dryRun:(BOOL)dry
                 conflicts:(NSMutableArray *)conflicts {
    BOOL upload = [cfg[@"upload"] boolValue], directory = [cfg[@"directory"] boolValue];
    NSString *local = cfg[@"local"], *remote = cfg[@"remote"], *binary = cfg[@"binary"], *server = cfg[@"server"];
    if (![local hasPrefix:@"/"] || ![remote hasPrefix:@"/"] || ![server hasPrefix:@"/"] || ![binary hasPrefix:@"/"])
        return @{@"error" : @"Select absolute file and rsync paths."};
    NSString *parentPath = local.stringByDeletingLastPathComponent;
    NSString *localName = local.lastPathComponent;
    if ([localName isEqual:@"."] || [localName isEqual:@".."] || !localName.length)
        return @{@"error" : @"Select a named file or folder."};
    local = [@"./" stringByAppendingString:localName];
    BOOL enterDestination = !upload && directory && (!dry || [cfg[@"destinationExists"] boolValue]);
    if (enterDestination)
        local = @".";
    if (directory) {
        if (upload)
            local = [local stringByAppendingString:@"/"];
        else
            remote = [remote stringByAppendingString:@"/"];
    }
    NSString *helper = [[NSBundle.mainBundle.executablePath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"FarcastRsync"];
    // rsync's -e lexer supports doubled single quotes inside a quoted word.
    NSString *rsh = [NSString stringWithFormat:@"'%@'", [helper stringByReplacingOccurrencesOfString:@"'"
                                                                                          withString:@"''"]];
    NSMutableArray *args =
        [NSMutableArray arrayWithObjects:binary, cfg[@"approvedNames"] ? @"-t" : @"-rt", @"--links", @"--partial",
                                         @"--rsync-path=farcast-rsync", @"-e", rsh, nil];
    if (cfg[@"approvedNames"]) {
        [args addObjectsFromArray:@[ @"--existing", @"--dirs", @"--from0", @"--files-from=-" ]];
    }
    if (dry)
        [args addObjectsFromArray:@[ @"--dry-run", @"--itemize-changes", @"--out-format=FC%i|%n" ]];
    else
        [args addObjectsFromArray:@[ @"--progress", @"--out-format=FC%i|%n" ]];
    if ([cfg[@"compress"] boolValue])
        [args addObject:@"-z"];
    if ([cfg[@"policy"] isEqual:@"skip"])
        [args addObject:@"--ignore-existing"];
    [args addObjectsFromArray:cfg[@"extra"] ?: @[]];
    NSString *operand = [@"peer:" stringByAppendingString:remote];
    [args addObjectsFromArray:@[ @"--", upload ? local : operand, upload ? operand : local ]];
    int bridge[2] = {-1, -1}, output[2] = {-1, -1}, streams[2] = {-1, -1};
    pid_t pid = -1;
    LIBSSH2_CHANNEL *channel = NULL;
    BOOL started = NO, eofSent = NO, ended = NO, failed = NO, remoteComplete = NO;
    int childStatus = 0, remoteStatus = -1;
    NSMutableData *lines = [NSMutableData data];
    NSString *failure = nil;
    // Anchor the child in the selected directory. Walking from / would ask
    // for read access to ancestors outside the user's selection.
    int parentFD = open(parentPath.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (parentFD < 0)
        return @{@"error" : @"Could not open the selected local folder."};
    if (enterDestination) {
        if (!dry && mkdirat(parentFD, localName.fileSystemRepresentation, 0700) && errno != EEXIST) {
            closeFD(&parentFD);
            return @{@"error" : @"Could not create the download folder."};
        }
        int folder =
            openat(parentFD, localName.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        closeFD(&parentFD);
        if (folder < 0)
            return @{@"error" : @"Could not open the download folder."};
        parentFD = folder;
    }
    FILE *fileList = NULL;
    NSData *names = cfg[@"approvedNames"];
    if (names) {
        fileList = tmpfile();
        if (!fileList || fwrite(names.bytes, 1, names.length, fileList) != names.length || fflush(fileList) ||
            fseek(fileList, 0, SEEK_SET)) {
            if (fileList)
                fclose(fileList);
            closeFD(&parentFD);
            return @{@"error" : @"Could not prepare the confirmed file list."};
        }
    }
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, bridge) || pipe(output))
        goto cleanup;
    {
        posix_spawn_file_actions_t actions;
        posix_spawnattr_t attributes;
        posix_spawn_file_actions_init(&actions);
        posix_spawnattr_init(&attributes);
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP);
        posix_spawnattr_setpgroup(&attributes, 0);
        posix_spawn_file_actions_addfchdir(&actions, parentFD);
        // Sources are duplicated by the actions before descriptor 9 is assigned.
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);

        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
        if (fileList)
            posix_spawn_file_actions_adddup2(&actions, fileno(fileList), STDIN_FILENO);
        else
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        posix_spawn_file_actions_adddup2(&actions, bridge[1], 9);
        char **argv = calloc(args.count + 1, sizeof(*argv));
        for (NSUInteger i = 0; i < args.count; i++)
            argv[i] = (char *)[args[i] UTF8String];
        char *env[] = {"LC_ALL=C", "PATH=/usr/bin:/bin", NULL};
        int rc = posix_spawn(&pid, binary.fileSystemRepresentation, &actions, &attributes, argv, env);
        free(argv);
        posix_spawnattr_destroy(&attributes);
        posix_spawn_file_actions_destroy(&actions);
        if (rc) {
            pid = -1;
            goto cleanup;
        }
    }
    closeFD(&bridge[1]);
    closeFD(&output[1]);
    nonblocking(output[0]);
    {
        char outgoing[32768], incoming[32768];
        size_t outSize = 0, inSize = 0, inOffset = 0;
        double deadline = monotonicTime() + 5;
        while (!atomic_load(&_stopped) && !atomic_load(&_filesCancelled)) {
            @autoreleasepool {
                BOOL activity = NO;
                char bytes[8192];
                ssize_t n = read(output[0], bytes, sizeof(bytes));
                if (n > 0) {
                    activity = YES;
                    for (ssize_t i = 0; i < n; i++) {
                        if (bytes[i] != '\n' && bytes[i] != '\r') {
                            if (lines.length < 8192)
                                [lines appendBytes:bytes + i length:1];
                            continue;
                        }
                        NSString *line = [[NSString alloc] initWithData:lines encoding:NSUTF8StringEncoding];
                        [lines setLength:0];
                        if ([line hasPrefix:@"FC"]) {
                            // Protocol 29 reports fewer itemized attributes than newer peers.
                            NSRange divider = [line rangeOfString:@"|"];
                            if (divider.location == NSNotFound || divider.location < 5) {
                                failed = YES;
                                break;
                            }
                            NSString *name = itemizedName([line substringFromIndex:NSMaxRange(divider)]);
                            if (dry && [line characterAtIndex:3] != 'd' && [line characterAtIndex:4] != '+') {
                                if (!name || conflicts.count >= 20000) {
                                    failed = YES;
                                    break;
                                }
                                // openrsync protocol 29 also uses >f....... for new downloads.
                                // Consult the actual destination before asking to replace it.
                                if ([cfg[@"destinationExists"] boolValue]) {
                                    NSString *target =
                                        directory ? [cfg[@"local"] stringByAppendingPathComponent:name] : cfg[@"local"];
                                    struct stat existing;
                                    if (upload || lstat(target.fileSystemRepresentation, &existing) == 0)
                                        [conflicts addObject:name];
                                    else if (errno != ENOENT) {
                                        failed = YES;
                                        break;
                                    }
                                }
                            } else if (!dry && self.onRsyncProgress && name) {
                                self.onRsyncProgress(requestID,
                                                     [@"item:" stringByAppendingString:name.lastPathComponent]);
                            }
                        } else if (!dry && self.onRsyncProgress && [line containsString:@"%"] &&
                                   [line containsString:@"/s"]) {
                            self.onRsyncProgress(requestID, line);
                        }
                    }
                }
                if (failed)
                    break;
                if (!started && !ended) {
                    struct pollfd poller = {bridge[0], POLLIN, 0};
                    if (poll(&poller, 1, 0) > 0) {
                        NSString *command = receiveStreams(bridge[0], streams, server, remote);
                        if (!command || !nonblocking(streams[0]) || !nonblocking(streams[1]))
                            break;
                        // rsync's standard streams may be sockets or pipes. Darwin
                        // suppresses SIGPIPE per descriptor for both.
                        fcntl(streams[1], F_SETNOSIGPIPE, 1);
                        channel = [self rsyncChannel:command];
                        if (!channel)
                            break;
                        started = YES;
                        activity = YES;
                    } else if (monotonicTime() > deadline)
                        break;
                }
                if (channel && !remoteComplete) {
                    if (!outSize && streams[0] >= 0) {
                        n = read(streams[0], outgoing, sizeof(outgoing));
                        if (n > 0)
                            outSize = n;
                        else if (n == 0)
                            closeFD(&streams[0]);
                        else if (errno != EAGAIN && errno != EINTR) {
                            failed = YES;
                            break;
                        }
                    }
                    if (outSize) {
                        n = libssh2_channel_write(channel, outgoing, outSize);
                        if (n > 0) {
                            outSize -= n;
                            memmove(outgoing, outgoing + n, outSize);
                            activity = YES;
                        } else if (n < 0 && n != LIBSSH2_ERROR_EAGAIN) {
                            failed = YES;
                            break;
                        }
                    } else if (streams[0] < 0 && !eofSent) {
                        int rc = libssh2_channel_send_eof(channel);
                        if (!rc)
                            eofSent = YES;
                        else if (rc != LIBSSH2_ERROR_EAGAIN) {
                            failed = YES;
                            break;
                        }
                    }
                    if (!inSize) {
                        n = libssh2_channel_read(channel, incoming, sizeof(incoming));
                        if (n > 0) {
                            inSize = n;
                            inOffset = 0;
                        } else if (libssh2_channel_eof(channel)) {
                            shutdown(streams[1], SHUT_WR);
                            closeFD(&streams[1]);
                            int rc;
                            double end = monotonicTime() + 5;
                            do {
                                rc = libssh2_channel_close(channel);
                            } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:end]);
                            remoteStatus = libssh2_channel_get_exit_status(channel);
                            uint8_t status = rc ? 255 : (uint8_t)remoteStatus;
                            send(bridge[0], &status, 1, 0);
                            remoteComplete = YES;
                        } else if (n < 0 && n != LIBSSH2_ERROR_EAGAIN) {
                            failed = YES;
                            break;
                        }
                    }
                    if (inSize) {
                        n = write(streams[1], incoming + inOffset, inSize);
                        if (n > 0) {
                            inOffset += n;
                            inSize -= n;
                            activity = YES;
                        } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                            failed = YES;
                            break;
                        }
                    }
                }
                if (started && !outSize)
                    [self servicePendingFileListing];
                if (!ended)
                    ended = waitpid(pid, &childStatus, WNOHANG) == pid;
                if (ended && n <= 0 && !activity)
                    break;
                if (![self serviceInteractive]) {
                    failed = YES;
                    break;
                }
                if (!activity)
                    [self waitForServiceEvents:POLLIN timeout:5];
            }
        }
    }
cleanup:
    if (fileList)
        fclose(fileList);
    closeFD(&parentFD);
    if (pid > 0 && (!ended || !remoteComplete)) {
        kill(-pid, SIGTERM);
        if (!ended) {
            for (int i = 0; i < 20 && !(ended = waitpid(pid, &childStatus, WNOHANG) == pid); i++)
                usleep(5000);
            if (!ended) {
                kill(-pid, SIGKILL);
                waitpid(pid, &childStatus, 0);
            }
        }
    }
    for (int i = 0; i < 2; i++) {
        closeFD(&bridge[i]);
        closeFD(&output[i]);
        closeFD(&streams[i]);
    }
    if (channel)
        [self releaseRsyncChannel:channel];
    if (atomic_load(&_stopped) || atomic_load(&_filesCancelled))
        return @{@"error" : @"Transfer cancelled."};
    int code = WIFEXITED(childStatus) ? WEXITSTATUS(childStatus) : 255;
    if (!started || (dry && (code == 2 || code == 12 || code == 127 || code == 255 || remoteStatus == 127)))
        return @{@"error" : @"rsync could not start on this connection.", @"startup" : @YES};
    if (failed || !ended || code || !remoteComplete || remoteStatus) {
        if (code == 23 || code == 24)
            failure = @"rsync reported a partial transfer. Inspect the destination.";
        else if (code == 11)
            failure = @"rsync could not write file data. Check disk space and permissions.";
        else
            failure = @"rsync stopped. Check permissions and inspect the destination for partial files.";
        return @{@"error" : failure};
    }
    return @{};
}
- (NSDictionary *)performRsync:(NSDictionary *)request {
    if ([request[@"kind"] isEqual:@"probeRsync"])
        return [self rsyncProbe:request[@"override"]];
    NSMutableDictionary *cfg = [request[@"config"] mutableCopy];
    if (![self openSFTPUntil:monotonicTime() + 15])
        return @{@"error" : @"Could not inspect the transfer paths."};
    BOOL upload = [cfg[@"upload"] boolValue];
    NSDictionary *source = upload ? [self localAttributes:cfg[@"local"]] : [self remoteAttributes:cfg[@"remote"]];
    NSDictionary *destination = upload ? [self remoteAttributes:cfg[@"remote"]] : [self localAttributes:cfg[@"local"]];
    if (!source || (![source[@"regular"] boolValue] && ![source[@"directory"] boolValue]))
        return @{@"error" : @"Select a file or folder."};
    if (destination && !destination[@"error"] &&
        ([source[@"directory"] boolValue] != [destination[@"directory"] boolValue] ||
         (![destination[@"regular"] boolValue] && ![destination[@"directory"] boolValue])))
        return @{@"error" : @"The destination has a different file type."};
    cfg[@"destinationExists"] = @(!destination[@"error"]);
    BOOL directory = [source[@"directory"] boolValue];
    cfg[@"directory"] = source[@"directory"];
    NSMutableArray *conflicts = [NSMutableArray new];
    NSDictionary *result = [self runRsync:cfg requestID:request[@"id"] dryRun:YES conflicts:conflicts];
    if (result[@"error"])
        return result;
    if ([cfg[@"policy"] isEqual:@"ask"]) {
        for (NSString *item in conflicts) {
            if (![self approveReplacement:item])
                return @{@"error" : @"Transfer stopped."};
        }
        if (directory && conflicts.count) {
            // Overwrite exactly the names approved during preflight. A second
            // exclusive pass copies new items without replacing a racing creator.
            NSMutableData *names = [NSMutableData data];
            for (NSString *item in conflicts) {
                [names appendData:[item dataUsingEncoding:NSUTF8StringEncoding]];
                [names appendBytes:"" length:1];
            }
            cfg[@"approvedNames"] = names;
            result = [self runRsync:cfg requestID:request[@"id"] dryRun:NO conflicts:conflicts];
            [cfg removeObjectForKey:@"approvedNames"];
            if (result[@"error"])
                return result;
        }
        if (directory || !conflicts.count)
            cfg[@"policy"] = @"skip";
    }
    result = [self runRsync:cfg requestID:request[@"id"] dryRun:NO conflicts:conflicts];
    if (directory && conflicts.count && result[@"startup"])
        return @{@"error" : @"The confirmed files were copied, but rsync could not restart to copy new files."};
    return result;
}
@end
