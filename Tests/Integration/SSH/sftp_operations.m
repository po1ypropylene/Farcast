#import "SSHClient.h"
#import <Foundation/Foundation.h>

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
        check(approvals == 1, @"shared-trust");
        [client disconnect];
        return failures ? 1 : 0;
    }
}
