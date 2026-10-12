#import "SSHClientInternal.h"
#import <fcntl.h>
#import <poll.h>
#import <sys/stat.h>
#import <unistd.h>

@implementation FCSSHClient (SFTPTreeWorker)
// Recursive operations stay on the transport worker. A manifest is built before
// changing the destination: symlinks/special files fail rather than silently skip.
- (NSDictionary *)remoteAttributes:(NSString *)path {
    LIBSSH2_SFTP_ATTRIBUTES attrs = {0};
    double deadline = monotonicTime() + 30;
    int rc;
    do {
        rc = libssh2_sftp_lstat(_sftp, path.UTF8String, &attrs);
    } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
    if (rc || !(attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS))
        return @{@"error" : @"Could not inspect the server item."};
    return remoteSnapshot(attrs);
}
- (NSDictionary *)localAttributes:(NSString *)path {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st))
        return @{@"error" : @"Could not inspect the local item."};
    return @{
        @"directory" : @(S_ISDIR(st.st_mode)),
        @"regular" : @(S_ISREG(st.st_mode)),
        @"size" : @(S_ISREG(st.st_mode) ? st.st_size : 0),
        @"modified" : @(st.st_mtimespec.tv_sec),
        @"nanos" : @(st.st_mtimespec.tv_nsec),
        @"inode" : @(st.st_ino)
    };
}
- (NSString *)appendName:(NSString *)name toPath:(NSString *)path {
    return [path isEqual:@"/"] ? [@"/" stringByAppendingString:name] : [NSString stringWithFormat:@"%@/%@", path, name];
}
- (BOOL)scanPath:(NSString *)path
          remote:(BOOL)remote
        relative:(NSString *)relative
           depth:(NSUInteger)depth
        manifest:(NSMutableArray *)manifest
       requestID:(NSString *)requestID {
    if (atomic_load(&_stopped) || atomic_load(&_filesCancelled) || depth > 64 || manifest.count >= 20000)
        return NO;
    return [self scanPath:path
                   remote:remote
                 relative:relative
                    depth:depth
                 manifest:manifest
                requestID:requestID
          knownAttributes:nil];
}
- (BOOL)scanPath:(NSString *)path
             remote:(BOOL)remote
           relative:(NSString *)relative
              depth:(NSUInteger)depth
           manifest:(NSMutableArray *)manifest
          requestID:(NSString *)requestID
    knownAttributes:(NSDictionary *)knownAttributes {
    if (atomic_load(&_stopped) || atomic_load(&_filesCancelled) || depth > 64 || manifest.count >= 20000)
        return NO;
    // READDIR already carries metadata. Reuse complete snapshots for preflight,
    // with LSTAT fallback for servers omitting fields. Transfer-time source
    // identity/metadata rechecks and move-deletion checks remain independent.
    NSDictionary *attrs = knownAttributes ?: (remote ? [self remoteAttributes:path] : [self localAttributes:path]);
    if (attrs[@"error"] || (![attrs[@"directory"] boolValue] && ![attrs[@"regular"] boolValue]))
        return NO;
    [manifest addObject:@{@"relative" : relative, @"attributes" : attrs}];
    if (![attrs[@"directory"] boolValue])
        return YES;
    NSArray *names;
    NSMutableDictionary *snapshots = [NSMutableDictionary new];
    if (remote) {
        NSDictionary *listing = [self performFileRequest:@{@"id" : requestID, @"path" : path, @"kind" : @"list"}];
        if (listing[@"error"])
            return NO;
        names = [listing[@"entries"] valueForKey:@"name"];
        for (NSDictionary *entry in listing[@"entries"]) {
            NSDictionary *snapshot = entry[@"snapshot"];
            if (snapshot.count)
                snapshots[entry[@"name"]] = snapshot;
        }
    } else {
        names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
        if (!names)
            return NO;
    }
    names = [names sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        if (!name.length || [name isEqual:@"."] || [name isEqual:@".."] || [name containsString:@"/"] ||
            [name rangeOfString:@"\0"].location != NSNotFound)
            return NO;
        NSString *child = [self appendName:name toPath:path];
        NSString *rel = relative.length ? [self appendName:name toPath:relative] : name;
        if (![self scanPath:child
                         remote:remote
                       relative:rel
                          depth:depth + 1
                       manifest:manifest
                      requestID:requestID
                knownAttributes:snapshots[name]])
            return NO;
    }
    return YES;
}
- (NSString *)makeRemoteDirectory:(NSString *)path {
    int rc;
    double deadline = monotonicTime() + 30;
    do {
        rc = libssh2_sftp_mkdir(_sftp, path.UTF8String, 0700);
    } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
    return rc ? @"Could not create the server folder. Existing items are never replaced." : nil;
}
- (NSString *)removeManifest:(NSArray *)manifest root:(NSString *)root remote:(BOOL)remote {
    for (NSDictionary *entry in [manifest reverseObjectEnumerator]) {
        if (atomic_load(&_stopped) || atomic_load(&_filesCancelled))
            return @"Deletion interrupted; some source items may remain.";
        NSString *rel = entry[@"relative"];
        NSString *path = rel.length ? [self appendName:rel toPath:root] : root;
        BOOL directory = [entry[@"attributes"][@"directory"] boolValue];
        NSDictionary *current = remote ? [self remoteAttributes:path] : [self localAttributes:path];
        if (current[@"error"] ||
            (directory ? ![current[@"directory"] boolValue] : ![current isEqual:entry[@"attributes"]]))
            return @"A source item changed during deletion. Stopped; some source items may remain.";
        if (remote) {
            int rc;
            double deadline = monotonicTime() + 30;
            do {
                rc = directory ? libssh2_sftp_rmdir(_sftp, path.UTF8String)
                               : libssh2_sftp_unlink(_sftp, path.UTF8String);
            } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
            if (rc)
                return @"Could not remove a source item. Some items may remain.";
        } else {
            int rc = directory ? rmdir(path.fileSystemRepresentation) : unlink(path.fileSystemRepresentation);
            if (rc)
                return @"Could not remove a local source item. Some items may remain.";
        }
        if (![self pumpTerminal:_workerChannel]) {
            [self disconnect];
            return @"Connection interrupted.";
        }
    }
    return nil;
}
- (NSDictionary *)performTreeOperation:(NSDictionary *)request {
    NSString *kind = request[@"kind"], *source = request[@"path"], *destination = request[@"destination"],
             *requestID = request[@"id"];
    if ([destination rangeOfString:@"\0"].location != NSNotFound)
        return @{@"error" : @"Invalid destination path."};
    if ([kind isEqual:@"mkdir"]) {
        NSString *failure = [self makeRemoteDirectory:source];
        return failure ? @{@"error" : failure} : @{};
    }
    if ([kind isEqual:@"rename"]) {
        if ([source isEqual:destination] || [destination hasPrefix:[source stringByAppendingString:@"/"]])
            return @{@"error" : @"Choose a different destination outside the source folder."};
        LIBSSH2_SFTP_ATTRIBUTES attrs = {0};
        int rc;
        double deadline = monotonicTime() + 30;
        do {
            rc = libssh2_sftp_lstat(_sftp, destination.UTF8String, &attrs);
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
        if (rc == 0 || libssh2_sftp_last_error(_sftp) != LIBSSH2_FX_NO_SUCH_FILE)
            return @{@"error" : @"The destination exists or cannot be checked."};
        do {
            rc = libssh2_sftp_rename_ex(_sftp, source.UTF8String, (unsigned int)strlen(source.UTF8String),
                                        destination.UTF8String, (unsigned int)strlen(destination.UTF8String), 0);
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
        return rc ? @{@"error" : @"Could not rename or move the server item. No replacement was requested."} : @{};
    }
    BOOL upload = [kind isEqual:@"uploadTree"];
    BOOL remoteCopy = [kind isEqual:@"copyRemote"];
    BOOL remove = [kind isEqual:@"removeTree"];
    if (!upload && !remoteCopy && !remove && ![kind isEqual:@"downloadTree"])
        return @{@"error" : @"Unsupported file operation."};
    if ([source isEqual:@"/"] || [source isEqual:@"."] || [source isEqual:@".."] || [source hasSuffix:@"/.."] ||
        [source hasSuffix:@"/."])
        return @{@"error" : @"Select an item inside a folder."};
    if (remoteCopy) {
        // Canonicalize the destination parent so ../ cannot bypass the descendant guard.
        NSString *parent = [destination stringByDeletingLastPathComponent];
        NSDictionary *resolved = [self performFileRequest:@{@"kind" : @"list", @"path" : parent, @"id" : requestID}];
        if (resolved[@"error"])
            return resolved;
        destination = [self appendName:destination.lastPathComponent toPath:resolved[@"path"]];
        NSDictionary *srcParent = [self performFileRequest:@{
            @"kind" : @"list",
            @"path" : source.stringByDeletingLastPathComponent,
            @"id" : requestID
        }];
        if (srcParent[@"error"])
            return srcParent;
        source = [self appendName:source.lastPathComponent toPath:srcParent[@"path"]];
        if ([source isEqual:destination] || [destination hasPrefix:[source stringByAppendingString:@"/"]])
            return @{@"error" : @"A folder cannot be pasted into itself."};
    }
    NSMutableArray *manifest = [NSMutableArray new];
    if (![self scanPath:source remote:!upload relative:@"" depth:0 manifest:manifest requestID:requestID])
        return @{
            @"error" : @"Could not read the complete source tree. Links, special files, more than 20,000 items or more "
                       @"than 64 folder levels are not supported. No source items were removed."
        };
    if (remove) {
        NSString *failure = [self removeManifest:manifest root:source remote:YES];
        return failure ? @{@"error" : failure} : @{};
    }
    NSString *temporary = nil;
    NSString *target = destination;
    if (remoteCopy) {
        NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Farcast-copy-XXXXXX"];
        char *buffer = strdup(template.fileSystemRepresentation);
        char *made = mkdtemp(buffer);
        if (made)
            temporary = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:made length:strlen(made)];
        free(buffer);
        if (!temporary)
            return @{@"error" : @"Could not create a temporary transfer folder."};
        target = [temporary stringByAppendingPathComponent:@"item"];
    }
    NSString *failure = nil;
    for (NSDictionary *entry in manifest) {
        if (atomic_load(&_stopped) || atomic_load(&_filesCancelled)) {
            failure = @"Transfer cancelled. Partial destination items may remain; sources were retained.";
            break;
        }
        NSString *rel = entry[@"relative"];
        NSString *src = rel.length ? [self appendName:rel toPath:source] : source;
        NSString *dst = rel.length ? [self appendName:rel toPath:target] : target;
        NSDictionary *current = upload ? [self localAttributes:src] : [self remoteAttributes:src];
        if (![current isEqual:entry[@"attributes"]]) {
            failure = @"A source item changed. Stopped without removing sources; partial destination items may remain.";
            break;
        }
        if ([entry[@"attributes"][@"directory"] boolValue]) {
            NSDictionary *existing =
                self.onFileConflict ? (upload ? [self remoteAttributes:dst] : [self localAttributes:dst]) : nil;
            if (![existing[@"directory"] boolValue]) {
                if (upload)
                    failure = [self makeRemoteDirectory:dst];
                else if (mkdir(dst.fileSystemRepresentation, 0700))
                    failure = @"Could not create a local destination folder. Existing items are never replaced.";
            }
        } else {
            NSDictionary *leaf = [self performFileRequest:@{
                @"id" : requestID,
                @"kind" : upload ? @"upload" : @"download",
                @"local" : upload ? src : dst,
                @"path" : upload ? dst : src
            }];
            failure = leaf[@"error"];
        }
        if (failure)
            break;
    }
    if (!failure && remoteCopy) {
        NSDictionary *copied = [self performTreeOperation:@{
            @"id" : requestID,
            @"kind" : @"uploadTree",
            @"path" : target,
            @"destination" : destination,
            @"move" : @NO
        }];
        failure = copied[@"error"];
    }
    if (temporary)
        [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
    if (!failure && [request[@"move"] boolValue]) {
        NSMutableArray *current = [NSMutableArray new];
        if (![self scanPath:source remote:!upload relative:@"" depth:0 manifest:current requestID:requestID] ||
            ![current isEqual:manifest])
            failure = @"The copy completed, but the source changed. The source was not removed.";
        else
            failure = [self removeManifest:manifest root:source remote:!upload];
    }
    if (failure)
        return @{@"error" : failure};
    return @{@"items" : @(manifest.count)};
}

@end
