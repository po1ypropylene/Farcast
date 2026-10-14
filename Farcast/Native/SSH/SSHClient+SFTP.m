#import "SSHClientInternal.h"
#import <fcntl.h>
#import <poll.h>
#import <sys/stat.h>
#import <unistd.h>

@implementation FCSSHClient (SFTPWorker)
- (BOOL)openSFTPUntil:(double)deadline {
    if (_sftp)
        return YES;
    if (_filesUnavailable)
        return NO;
    if (![self drainForwardOpenUntil:deadline])
        return NO;
    _channelOpenBusy = YES;
    do {
        _sftp = libssh2_sftp_init(_workerSession);
    } while (!_sftp && libssh2_session_last_errno(_workerSession) == LIBSSH2_ERROR_EAGAIN &&
             [self waitForFileUntil:deadline]);
    _channelOpenBusy = NO;
    if (!_sftp && !atomic_load(&_stopped)) {
        _filesUnavailable = YES;
        if (self.onFileAvailability)
            self.onFileAvailability(NO);
    }
    return _sftp != NULL;
}
- (BOOL)pumpIdleSFTP {
    LIBSSH2_CHANNEL *channel = libssh2_sftp_get_channel(_sftp);
    // Read only extended data: the subsystem owns all standard-stream bytes.
    // This drains SSH control packets/keepalive replies without consuming SFTP replies.
    char ignored[1024];
    ssize_t count = libssh2_channel_read_ex(channel, SSH_EXTENDED_DATA_STDERR, ignored, sizeof(ignored));
    return (count >= 0 || count == LIBSSH2_ERROR_EAGAIN) && !libssh2_channel_eof(channel);
}
- (void)enqueueFileRequest:(NSDictionary *)request {
    [_lock lock];
    BOOL accepted = !atomic_load(&_stopped) && _fileRequests.count < 8;
    if (accepted)
        [_fileRequests addObject:request];
    [_lock unlock];
    if (!accepted && self.onFiles)
        self.onFiles(request[@"id"], @{}, @"The file request could not be queued.");
}
- (BOOL)approveReplacement:(NSString *)path {
    if (!self.onFileConflict)
        return NO;
    NSString *token = NSUUID.UUID.UUIDString;
    [_lock lock];
    _conflictToken = token;
    _conflictChoice = -1;
    [_lock unlock];
    self.onFileConflict(token, path.lastPathComponent);
    NSInteger choice = -1;
    while (!atomic_load(&_stopped) && !atomic_load(&_filesCancelled)) {
        [_lock lock];
        choice = _conflictChoice;
        [_lock unlock];
        if (choice >= 0)
            break;
        if (![self serviceInteractive]) {
            [self disconnect];
            break;
        }
        [self waitForServiceEvents:POLLIN timeout:20];
    }
    [_lock lock];
    _conflictToken = nil;
    [_lock unlock];
    return choice == 1 && !atomic_load(&_stopped) && !atomic_load(&_filesCancelled);
}
- (BOOL)waitForFileUntil:(double)deadline {
    // Preserve SFTP's readiness directions before terminal reads change the
    // session's last-operation directions. POLLOUT must not become POLLIN.
    int direction = libssh2_session_block_directions(_workerSession);
    short events = 0;
    if (direction & LIBSSH2_SESSION_BLOCK_INBOUND)
        events |= POLLIN;
    if (direction & LIBSSH2_SESSION_BLOCK_OUTBOUND)
        events |= POLLOUT;
    if (!events)
        events = POLLIN | POLLOUT;
    if (monotonicTime() - _lastTerminalPump > 0.01) {
        _lastTerminalPump = monotonicTime();
        if (![self serviceInteractive]) {
            [self disconnect];
            return NO;
        }
        // A terminal write may also need socket readiness. Preserve both
        // operations' directions, rather than waiting only for SFTP replies.
        int terminalDirection = _terminalWaitDirections | _forwardWaitDirections;
        if (terminalDirection & LIBSSH2_SESSION_BLOCK_INBOUND)
            events |= POLLIN;
        if (terminalDirection & LIBSSH2_SESSION_BLOCK_OUTBOUND)
            events |= POLLOUT;
    }
    if (atomic_load(&_stopped) || monotonicTime() >= deadline) {
        [self disconnect];
        return NO;
    }
    [self
        waitForServiceEvents:events
                     timeout:((_workerChannel && atomic_load(&_terminalVisible)) || [self forwardingActive]) ? 10 : 50];
    return !atomic_load(&_stopped) && monotonicTime() < deadline;
}
- (NSDictionary *)performFileRequest:(NSDictionary *)request {
    if (atomic_load(&_filesCancelled))
        return @{@"error" : @"File operation cancelled."};
    NSString *requestID = request[@"id"], *path = request[@"path"];
    NSString *error = nil;
    NSDictionary *result = @{};
    LIBSSH2_SFTP_HANDLE *handle = NULL;
    int fd = -1;
    BOOL upload = [request[@"kind"] isEqualToString:@"upload"];
    BOOL listing = [request[@"kind"] isEqualToString:@"list"];
    BOOL created = NO, complete = NO;
    NSString *stagingPath = nil;
    NSString *remoteStaging = nil;
    BOOL replacing = NO;
    unsigned long long bytes = 0, total = 0;
    double deadline = monotonicTime() + 30;
    int rc = 0;
    if ([path rangeOfString:@"\0"].location != NSNotFound ||
        (request[@"local"] && [request[@"local"] rangeOfString:@"\0"].location != NSNotFound)) {
        error = @"Invalid file path.";
        goto finish;
    }
    if (![self openSFTPUntil:deadline]) {
        error = @"The server could not open SFTP. Check that file transfer is enabled.";
        goto finish;
    }
    if (![request[@"kind"] isEqualToString:@"upload"] && ![request[@"kind"] isEqualToString:@"download"] && !listing) {
        return [self performTreeOperation:request];
    }
    if (listing) {
        char canonical[32768];
        do {
            rc = libssh2_sftp_realpath(_sftp, path.UTF8String, canonical, sizeof(canonical));
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
        if (rc <= 0 || rc >= sizeof(canonical)) {
            error = @"Could not resolve this server folder.";
            goto finish;
        }
        path = [[NSString alloc] initWithBytes:canonical length:rc encoding:NSUTF8StringEncoding];
        if (!path) {
            error = @"This server path is not valid UTF-8.";
            goto finish;
        }
    } else {
        NSString *localPath = request[@"local"];
        if (!upload) {
            struct stat existing;
            int found = lstat(localPath.fileSystemRepresentation, &existing);
            if (found == 0) {
                if (!S_ISREG(existing.st_mode) || ![self approveReplacement:localPath]) {
                    error = @"Transfer stopped. Existing destination was retained.";
                    goto finish;
                }
                replacing = YES;
            } else if (errno != ENOENT) {
                error = @"Could not check the local destination.";
                goto finish;
            }
            deadline = monotonicTime() + 30;
            stagingPath = [[localPath stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:[@".farcast-transfer-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        }
        const char *local = (upload ? localPath : stagingPath).fileSystemRepresentation;
        fd = open(local, upload ? O_RDONLY | O_NOFOLLOW : O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (fd < 0) {
            error = @"Could not open the local file. Existing files are never replaced.";
            goto finish;
        }
        created = !upload;
        struct stat st;
        if (fstat(fd, &st) || !S_ISREG(st.st_mode)) {
            error = @"Select a regular file to transfer.";
            goto finish;
        }
        if (upload)
            total = st.st_size;
    }
openRemote:
    do {
        NSString *openPath = remoteStaging ?: path;
        handle = libssh2_sftp_open_ex(_sftp, openPath.UTF8String, (unsigned int)strlen(openPath.UTF8String),
                                      listing  ? 0
                                      : upload ? LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL
                                               : LIBSSH2_FXF_READ,
                                      0600, listing ? LIBSSH2_SFTP_OPENDIR : LIBSSH2_SFTP_OPENFILE);
    } while (!handle && libssh2_session_last_errno(_workerSession) == LIBSSH2_ERROR_EAGAIN &&
             [self waitForFileUntil:deadline]);
    if (!handle && upload && self.onFileConflict && !remoteStaging && !atomic_load(&_filesCancelled) &&
        !atomic_load(&_stopped)) {
        // Exclusive create is the conflict check for new destinations: one request,
        // no replacement and no symlink following. Inspect only a failed create.
        LIBSSH2_SFTP_ATTRIBUTES existing = {0};
        do {
            rc = libssh2_sftp_lstat(_sftp, path.UTF8String, &existing);
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
        if (!rc) {
            if (!(existing.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) ||
                (existing.permissions & LIBSSH2_SFTP_S_IFMT) != LIBSSH2_SFTP_S_IFREG) {
                error = @"Only regular destination files can be overwritten.";
                goto finish;
            }
            if (![self approveReplacement:path]) {
                error = @"Transfer stopped. No replacement was made.";
                goto finish;
            }
            replacing = YES;
            remoteStaging = [self appendName:[@".farcast-transfer-" stringByAppendingString:NSUUID.UUID.UUIDString]
                                      toPath:path.stringByDeletingLastPathComponent];
            deadline = monotonicTime() + 30;
            goto openRemote;
        }
    }
    if (!handle) {
        error = @"Could not open the server item. Check permissions; existing files are never replaced.";
        goto finish;
    }
    if (upload)
        created = YES;
    if (listing) {
        NSMutableArray *entries = [NSMutableArray new];
        char name[32768];
        LIBSSH2_SFTP_ATTRIBUTES attrs;
        while (!atomic_load(&_stopped)) {
            memset(&attrs, 0, sizeof(attrs));
            rc = libssh2_sftp_readdir_ex(handle, name, sizeof(name), NULL, 0, &attrs);
            if (rc == LIBSSH2_ERROR_EAGAIN) {
                if ([self waitForFileUntil:deadline])
                    continue;
                break;
            }
            if (rc <= 0 || atomic_load(&_filesCancelled))
                break;
            if (entries.count >= 20000) {
                error = @"This folder exceeds the 20,000-item limit.";
                break;
            }
            NSString *entry = [[NSString alloc] initWithBytes:name length:rc encoding:NSUTF8StringEncoding];
            if ([entry isEqualToString:@"."] || [entry isEqualToString:@".."])
                continue;
            if (!entry || [entry containsString:@"/"] || [entry rangeOfString:@"\0"].location != NSNotFound) {
                error = @"This folder contains an unsupported filename.";
                break;
            }
            unsigned long type =
                (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) ? attrs.permissions & LIBSSH2_SFTP_S_IFMT : 0;
            [entries addObject:@{
                @"name" : entry,
                @"directory" : @(type == LIBSSH2_SFTP_S_IFDIR),
                @"regular" : @(type == LIBSSH2_SFTP_S_IFREG),
                @"size" : @(attrs.filesize),
                @"snapshot" : (attrs.flags & (LIBSSH2_SFTP_ATTR_PERMISSIONS | LIBSSH2_SFTP_ATTR_SIZE |
                                              LIBSSH2_SFTP_ATTR_ACMODTIME)) ==
                        (LIBSSH2_SFTP_ATTR_PERMISSIONS | LIBSSH2_SFTP_ATTR_SIZE | LIBSSH2_SFTP_ATTR_ACMODTIME)
                    ? remoteSnapshot(attrs)
                    : @{}
            }];
            if (![self serviceInteractive]) {
                [self disconnect];
                break;
            }
        }
        if (rc < 0 || atomic_load(&_stopped))
            error = @"The server folder could not be read completely.";
        result = @{@"path" : path, @"entries" : entries};
        complete = error == nil;
    } else {
        if (!upload) {
            LIBSSH2_SFTP_ATTRIBUTES attrs = {0};
            do {
                rc = libssh2_sftp_fstat(handle, &attrs);
            } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
            if (rc || !(attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) || !LIBSSH2_SFTP_S_ISREG(attrs.permissions)) {
                error = @"Only regular server files can be downloaded.";
                goto finish;
            }
            total = attrs.filesize;
        }
        // Mark each leaf's start so UI throughput never spans unrelated files.
        if (self.onFileProgress)
            self.onFileProgress(requestID, 0, total);
        // Files-only presentation retains the bulk pipeline. Interactive
        // presentation bounds data queued ahead of terminal packets on the
        // shared TCP stream (SFTP reads request four times the offered size).
        NSUInteger maximumWindow = upload ? 4 * 1024 * 1024 : 1024 * 1024;
        NSUInteger windowSize = (NSUInteger)MIN(MAX(1ULL, total), maximumWindow);
        NSMutableData *window = [NSMutableData dataWithLength:windowSize];
        char *buffer = window.mutableBytes;
        size_t bufferSize = window.length;
        double lastProgress = 0;
        while (!atomic_load(&_stopped) && !atomic_load(&_filesCancelled)) {
            size_t budget = ((_workerChannel && atomic_load(&_terminalVisible)) || [self forwardingActive])
                                ? MIN(bufferSize, upload ? 128 * 1024 : 32 * 1024)
                                : bufferSize;
            ssize_t count;
            do {
                count = upload ? read(fd, buffer, budget) : libssh2_sftp_read(handle, buffer, budget);
            } while (!upload && count == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
            if (atomic_load(&_filesCancelled))
                break;
            if (count == 0) {
                complete = bytes == total;
                break;
            }
            if (count < 0)
                break;
            ssize_t offset = 0;
            size_t offered = 0;
            while (offset < count && !atomic_load(&_stopped)) {
                if (!offered) {
                    budget = ((_workerChannel && atomic_load(&_terminalVisible)) || [self forwardingActive])
                                 ? MIN(bufferSize, 128 * 1024)
                                 : bufferSize;
                    offered = MIN(count - offset, budget);
                }
                ssize_t written = upload ? libssh2_sftp_write(handle, buffer + offset, offered)
                                         : write(fd, buffer + offset, count - offset);
                if (upload && (written == LIBSSH2_ERROR_EAGAIN || written == 0)) {
                    if ([self waitForFileUntil:deadline])
                        continue;
                    break;
                }
                if (written <= 0)
                    break;
                offset += written;
                bytes += written;
                offered = 0;
                deadline = monotonicTime() + 30;
                // Refill only after a positive acknowledgement, never on EAGAIN:
                // libssh2 requires identical unacknowledged bytes on retries.
                // Keeping the bounded window full avoids draining it between reads.
                if (upload && offset >= MAX(32 * 1024, budget / 4) && !atomic_load(&_filesCancelled)) {
                    size_t remaining = count - offset;
                    memmove(buffer, buffer + offset, remaining);
                    // After switching to Split, drain previously queued bulk
                    // bytes before adding more; a TCP stream cannot reorder them.
                    ssize_t added = remaining < budget ? read(fd, buffer + remaining, budget - remaining) : 0;
                    if (added < 0) {
                        error = @"Could not read the upload source.";
                        break;
                    }
                    count = remaining + added;
                    offset = 0;
                    if (self.onFileProgress && monotonicTime() - lastProgress >= 0.1) {
                        self.onFileProgress(requestID, bytes, total);
                        lastProgress = monotonicTime();
                    }
                }
                if (upload && monotonicTime() - _lastTerminalPump >= 0.01) {
                    _lastTerminalPump = monotonicTime();
                    if (![self serviceInteractive]) {
                        [self disconnect];
                        break;
                    }
                }
            }
            if (offset != count)
                break;
            if (![self serviceInteractive]) {
                [self disconnect];
                break;
            }
            if (self.onFileProgress && monotonicTime() - lastProgress >= 0.1) {
                self.onFileProgress(requestID, bytes, total);
                lastProgress = monotonicTime();
            }
        }
        if (!complete)
            error = @"Transfer interrupted. An incomplete file may remain on the server.";
        if (complete && self.onFileProgress)
            self.onFileProgress(requestID, bytes, total);
        result = @{@"bytes" : @(bytes)};
    }
finish:
    if (handle) {
        // Download read-ahead can leave up to four windows of replies ahead
        // of CLOSE on a slow peer. Allow bounded draining without abandoning
        // the shared login, and keep servicing terminal I/O while it completes.
        double closeDeadline = monotonicTime() + (upload || listing ? 5 : 10);
        do {
            rc = libssh2_sftp_close_handle(handle);
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:closeDeadline]);
        if (rc) {
            error = @"The server did not confirm closing the file. Check for an incomplete file.";
            complete = NO;
            [self disconnect];
        }
    }
    if (fd >= 0) {
        if (!upload && complete && fsync(fd)) {
            complete = NO;
            error = @"Could not finish writing the local file.";
        }
        close(fd);
    }
    if (!upload && created) {
        if (complete &&
            (replacing ? rename(stagingPath.fileSystemRepresentation, [request[@"local"] fileSystemRepresentation])
                       : link(stagingPath.fileSystemRepresentation, [request[@"local"] fileSystemRepresentation]))) {
            error = @"Could not save the download. The destination may already exist; no existing file was replaced.";
            complete = NO;
        }
        unlink(stagingPath.fileSystemRepresentation);
    }
    if (remoteStaging) {
        if (complete && !atomic_load(&_filesCancelled) && !atomic_load(&_stopped)) {
            // Atomic replacement never follows a destination symlink, and preserves
            // the old bytes until the entire upload and handle close succeed.
            deadline = monotonicTime() + 30;
            do {
                rc = libssh2_sftp_posix_rename(_sftp, remoteStaging.UTF8String, path.UTF8String);
            } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
            if (rc)
                error = @"The server could not atomically replace the file. The original was retained.";
        }
        if (!complete || error || atomic_load(&_filesCancelled)) {
            deadline = monotonicTime() + 5;
            do {
                rc = libssh2_sftp_unlink(_sftp, remoteStaging.UTF8String);
            } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
        }
    }
    // Leave an interrupted upload for the user to inspect. Deleting by remote
    // pathname could remove another client's replacement on a shared server.
    if (error)
        return @{@"error" : error};
    return result;
}

@end
