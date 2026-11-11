#import "SSHClient.h"
#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static BOOL verifyTree(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"nested/世界.bin"]];
    const uint8_t expected[] = {0, 1, 255, 3, 128};
    BOOL empty = [[NSFileManager defaultManager] fileExistsAtPath:[path stringByAppendingPathComponent:@"empty"]];
    return [data isEqual:[NSData dataWithBytes:expected length:sizeof(expected)]] && empty;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 4)
            return 2;
        NSString *root = @(argv[2]);
        NSString *pin = [NSString stringWithContentsOfFile:@(argv[3]) encoding:NSUTF8StringEncoding error:nil];
        FCSSHClient *client = [FCSSHClient new];
        dispatch_semaphore_t connected = dispatch_semaphore_create(0), response = dispatch_semaphore_create(0);
        __block NSDictionary *reply = nil;
        __block BOOL terminated = NO;
        __block int approvals = 0, failures = 0;
        client.onTrust = ^BOOL(NSString *fingerprint, NSString *details) {
          approvals++;
          return [fingerprint isEqual:pin];
        };
        client.onStatus = ^(NSString *status, NSString *message) {
          if ([status isEqual:@"connected"])
              dispatch_semaphore_signal(connected);
          if ([status isEqual:@"failed"] || [status isEqual:@"disconnected"]) {
              terminated = YES;
              dispatch_semaphore_signal(response);
          }
        };
        client.onFiles = ^(NSString *id, NSDictionary *result, NSString *error) {
          reply = error ? @{@"error" : error} : result;
          dispatch_semaphore_signal(response);
        };
        [client connectHost:@"127.0.0.1"
                       port:atoi(argv[1])
                   username:@"fixture"
                   password:@"fixture-password"
                 privateKey:nil
             authentication:@"password"];
        if (dispatch_semaphore_wait(connected, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)))
            return 1;
        NSDictionary * (^operation)(NSString *, NSString *, NSString *, BOOL) =
            ^NSDictionary *(NSString *kind, NSString *source, NSString *destination, BOOL move) {
              reply = nil;
              [client fileOperation:kind
                             source:source
                        destination:destination
                               move:move
                          requestID:NSUUID.UUID.UUIDString];
              if (dispatch_semaphore_wait(response, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) ||
                  terminated || !reply)
                  return @{@"error" : @"timeout"};
              return reply;
            };
        void (^check)(BOOL, NSString *) = ^(BOOL passed, NSString *name) {
          printf("%s SFTP operations %s\n", passed ? "PASS" : "FAIL", name.UTF8String);
          if (!passed)
              failures++;
        };
        NSFileManager *files = [NSFileManager defaultManager];
        NSString *source = [root stringByAppendingPathComponent:@"tree-source"];
        [files removeItemAtPath:source error:nil];
        [files createDirectoryAtPath:[source stringByAppendingPathComponent:@"nested"]
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
        [files createDirectoryAtPath:[source stringByAppendingPathComponent:@"empty"]
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
        const uint8_t bytes[] = {0, 1, 255, 3, 128};
        [[NSData dataWithBytes:bytes
                        length:sizeof(bytes)] writeToFile:[source stringByAppendingPathComponent:@"nested/世界.bin"]
                                               atomically:YES];
        NSData *metadataBytes = [NSData dataWithBytes:bytes length:sizeof(bytes)];
        [metadataBytes writeToFile:[source stringByAppendingPathComponent:@"metadata-lite.bin"] atomically:NO];
        check(operation(@"rename", @"/tree", @"", NO)[@"error"] != nil, @"missing-destination-refused");
        NSString *nulSource = [@"/tree" stringByAppendingString:[NSString stringWithCharacters:(unichar[]){0}
                                                                                        length:1]];
        check(operation(@"mkdir", nulSource, @"", NO)[@"error"] != nil, @"nul-source-refused");
        check(!operation(@"uploadTree", source, @"/tree", NO)[@"error"], @"recursive-upload");
        NSString *download = [root stringByAppendingPathComponent:@"tree-download"];
        [files removeItemAtPath:download error:nil];
        check(!operation(@"downloadTree", @"/tree", download, NO)[@"error"] && verifyTree(download),
              @"recursive-download-empty-and-unicode");
        check(
            [metadataBytes
                isEqual:[NSData dataWithContentsOfFile:[download stringByAppendingPathComponent:@"metadata-lite.bin"]]],
            @"incomplete-listing-metadata-falls-back-to-stat");
        NSString *raceSource = [root stringByAppendingPathComponent:@"listing-race-source"];
        [files createDirectoryAtPath:raceSource withIntermediateDirectories:YES attributes:nil error:nil];
        [metadataBytes writeToFile:[raceSource stringByAppendingPathComponent:@"listing-changed.bin"] atomically:NO];
        check(!operation(@"uploadTree", raceSource, @"/listing-race", NO)[@"error"], @"listing-race-seed");
        NSString *raceDownload = [root stringByAppendingPathComponent:@"listing-race-download"];
        check(operation(@"downloadTree", @"/listing-race", raceDownload, NO)[@"error"] != nil &&
                  ![files fileExistsAtPath:[raceDownload stringByAppendingPathComponent:@"listing-changed.bin"]],
              @"listing-snapshot-change-stops-before-leaf-copy");
        check(operation(@"uploadTree", source, @"/tree", YES)[@"error"] && verifyTree(source),
              @"failed-move-retains-source");
        check(!operation(@"copyRemote", @"/tree", @"/remote-copy", NO)[@"error"], @"remote-recursive-copy");
        NSString *copy = [root stringByAppendingPathComponent:@"copy-download"];
        [files removeItemAtPath:copy error:nil];
        check(!operation(@"downloadTree", @"/remote-copy", copy, NO)[@"error"] && verifyTree(copy),
              @"remote-copy-bytes");
        check(operation(@"copyRemote", @"/tree", @"/tree/inside", NO)[@"error"] != nil, @"self-descendant-refused");
        check(!operation(@"rename", @"/remote-copy", @"/renamed", NO)[@"error"], @"remote-folder-rename");
        check(operation(@"rename", @"/renamed", @"/tree", NO)[@"error"] != nil, @"rename-collision");
        check(!operation(@"mkdir", @"/destination", @"", NO)[@"error"] &&
                  !operation(@"rename", @"/renamed", @"/destination/moved", NO)[@"error"],
              @"remote-cut-paste");
        check(!operation(@"removeTree", @"/destination", @"", NO)[@"error"], @"recursive-delete");
        NSString *movedDownload = [root stringByAppendingPathComponent:@"moved-download"];
        [files removeItemAtPath:movedDownload error:nil];
        check(!operation(@"downloadTree", @"/tree", movedDownload, YES)[@"error"] && verifyTree(movedDownload),
              @"cross-side-move-to-local");
        NSString *absent = [root stringByAppendingPathComponent:@"absent"];
        [files removeItemAtPath:absent error:nil];
        check(operation(@"downloadTree", @"/tree", absent, NO)[@"error"] != nil && ![files fileExistsAtPath:absent],
              @"move-removed-remote-source");
        check(!operation(@"uploadTree", source, @"/moved-upload", YES)[@"error"] && ![files fileExistsAtPath:source],
              @"cross-side-move-to-server");
        NSString *linked = [root stringByAppendingPathComponent:@"linked-source"];
        [files removeItemAtPath:linked error:nil];
        [files createDirectoryAtPath:linked withIntermediateDirectories:YES attributes:nil error:nil];
        [files createSymbolicLinkAtPath:[linked stringByAppendingPathComponent:@"link"]
                    withDestinationPath:download
                                  error:nil];
        check(operation(@"uploadTree", linked, @"/linked", YES)[@"error"] != nil && [files fileExistsAtPath:linked],
              @"symlink-preflight-retains-source");
        NSString *linkedDownload = [root stringByAppendingPathComponent:@"link-download"];
        [files removeItemAtPath:linkedDownload error:nil];
        check(operation(@"downloadTree", @"/link", linkedDownload, YES)[@"error"] != nil &&
                  ![files fileExistsAtPath:linkedDownload],
              @"remote-link-not-followed");

        NSString *changed = [root stringByAppendingPathComponent:@"changed-source-download"];
        [files removeItemAtPath:changed error:nil];
        check(operation(@"downloadTree", @"/mutating.bin", changed, YES)[@"error"] != nil &&
                  [NSData dataWithContentsOfFile:changed].length == 32768,
              @"changed-source-stops-move-deletion");
        NSString *retained = [root stringByAppendingPathComponent:@"retained-download"];
        [files removeItemAtPath:retained error:nil];
        check(!operation(@"downloadTree", @"/mutating.bin", retained, NO)[@"error"], @"changed-source-still-readable");
        NSString *deepRoot = [root stringByAppendingPathComponent:@"deep-tree"];
        [files removeItemAtPath:deepRoot error:nil];
        NSString *deep = deepRoot;
        for (int depth = 0; depth < 66; depth++)
            deep = [deep stringByAppendingPathComponent:@"d"];
        [files createDirectoryAtPath:deep withIntermediateDirectories:YES attributes:nil error:nil];
        check(operation(@"uploadTree", deepRoot, @"/too-deep", YES)[@"error"] != nil && [files fileExistsAtPath:deep],
              @"depth-bound-retains-source");
        NSString *fifo = [root stringByAppendingPathComponent:@"upload-fifo"];
        check(mkfifo(fifo.fileSystemRepresentation, 0600) == 0, @"fifo-fixture");
        reply = nil;
        [client transferLocalPath:fifo remotePath:@"/fifo.bin" upload:YES requestID:@"fifo"];
        BOOL fifoReturned = dispatch_semaphore_wait(response, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
        check(fifoReturned && reply[@"error"] != nil, @"special-file-open-does-not-block-worker");
        if (!fifoReturned) {
            // Unblock the old implementation so a failing regression can still drain.
            int writer = open(fifo.fileSystemRepresentation, O_WRONLY | O_NONBLOCK);
            if (writer >= 0)
                close(writer);
            dispatch_semaphore_wait(response, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        }
        NSString *changing = [root stringByAppendingPathComponent:@"changing-upload.bin"];
        [metadataBytes writeToFile:changing atomically:NO];
        client.onFileProgress = ^(NSString *identifier, unsigned long long bytes, unsigned long long total) {
          if ([identifier isEqual:@"changing-upload"] && bytes == 0)
              [files setAttributes:@{NSFileModificationDate : [NSDate dateWithTimeIntervalSinceNow:60]}
                      ofItemAtPath:changing
                             error:nil];
        };
        reply = nil;
        [client transferLocalPath:changing remotePath:@"/changing-upload.bin" upload:YES requestID:@"changing-upload"];
        check(dispatch_semaphore_wait(response, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0 &&
                  reply[@"error"] != nil && [[NSData dataWithContentsOfFile:changing] isEqual:metadataBytes],
              @"changed-upload-source-reported-and-retained");
        // The failed new-file attempt left its bytes for inspection. A later
        // failed overwrite must preserve them until its staged source is stable.
        NSData *replacement = [NSData dataWithBytes:(uint8_t[]){9, 8, 7, 6, 5} length:5];
        [replacement writeToFile:changing atomically:NO];
        client.onFileConflict = ^(NSString *token, NSString *name) {
          [client resolveFileConflict:token overwrite:YES];
        };
        reply = nil;
        [client transferLocalPath:changing remotePath:@"/changing-upload.bin" upload:YES requestID:@"changing-upload"];
        check(dispatch_semaphore_wait(response, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0 &&
                  reply[@"error"] != nil,
              @"changed-overwrite-source-refused");
        client.onFileConflict = nil;
        client.onFileProgress = nil;
        NSString *original = [root stringByAppendingPathComponent:@"unchanged-upload-destination.bin"];
        reply = nil;
        [client transferLocalPath:original remotePath:@"/changing-upload.bin" upload:NO requestID:@"verify-upload"];
        check(dispatch_semaphore_wait(response, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0 &&
                  reply[@"error"] == nil && [[NSData dataWithContentsOfFile:original] isEqual:metadataBytes] &&
                  [[NSData dataWithContentsOfFile:changing] isEqual:replacement],
              @"changed-overwrite-retains-original-destination-and-source");
        check(approvals == 1, @"shared-trust");
        [client disconnect];
        dispatch_semaphore_t drained = dispatch_semaphore_create(0);
        [FCSSHClient whenAllDisconnected:^{
          dispatch_semaphore_signal(drained);
        }];
        check(dispatch_semaphore_wait(drained, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0,
              @"worker-drained-before-process-exit");
        return failures ? 1 : 0;
    }
}
