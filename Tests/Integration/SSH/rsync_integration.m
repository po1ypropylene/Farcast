#import "SSHClient.h"
#import <Foundation/Foundation.h>

int main(int argc, char **argv) {
    if (argc < 5)
        return 2;
    @autoreleasepool {
        FCSSHClient *client = [FCSSHClient new];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL ready = NO;
        NSString *pin = @(argv[3]);
        client.onTrust = ^BOOL(NSString *value, NSString *details) {
          return [pin isEqual:value];
        };
        client.onData = ^(NSData *data) {
        };
        client.onStatus = ^(NSString *status, NSString *message) {
          if ([status isEqual:@"connected"]) {
              ready = YES;
              dispatch_semaphore_signal(done);
          }
        };
        [client connectHost:@"127.0.0.1"
                       port:atoi(argv[1])
                   username:@"fixture"
                   password:@"fixture-password"
                 privateKey:nil
             authentication:@"password"];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) || !ready)
            return 3;
        __block NSDictionary *reply;
        client.onFiles = ^(NSString *identifier, NSDictionary *result, NSString *error) {
          reply = result;
          dispatch_semaphore_signal(done);
        };
        [client probeRsync:@"" requestID:@"probe"];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) ||
            ![reply[@"versions"] length])
            return 4;
        NSString *root = @(argv[2]), *binary = @(argv[4]);
        BOOL sandbox = [root isEqual:@"--sandbox"];
        if (sandbox) {
            root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            NSString *folder = [root stringByAppendingPathComponent:@"input"];
            if (![NSFileManager.defaultManager createDirectoryAtPath:folder
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil])
                return 7;
            NSMutableData *bytes = [NSMutableData dataWithLength:172032];
            arc4random_buf(bytes.mutableBytes, bytes.length);
            if (![bytes writeToFile:[folder stringByAppendingPathComponent:@"leaf"] atomically:YES])
                return 8;
        }
        NSString *nested = [root stringByAppendingPathComponent:@"input/nested/empty"];
        if (![NSFileManager.defaultManager createDirectoryAtPath:nested
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil])
            return 14;
        NSData *sentinel = [@"nested unicode leaf" dataUsingEncoding:NSUTF8StringEncoding];
        if (![sentinel writeToFile:[root stringByAppendingPathComponent:@"input/nested/二.txt"] atomically:YES])
            return 15;
        __block int conflicts = 0;
        __block BOOL stopOnConflict = NO;
        __weak FCSSHClient *weak = client;
        client.onFileConflict = ^(NSString *token, NSString *name) {
          if (stopOnConflict) {
              [weak cancelFiles];
              return;
          }
          conflicts++;
          [weak resolveFileConflict:token overwrite:YES];
        };
        for (int step = 0; step < 3; step++) {
            BOOL upload = step == 0;
            NSMutableDictionary *cfg = [@{
                @"local" : [root stringByAppendingPathComponent:upload ? @"input" : @"output"],
                @"remote" : @"/sample '$ demo",
                @"binary" : binary,
                @"server" : @"/fixture/rsync",
                @"upload" : @(upload),
                @"policy" : @"ask",
                @"compress" : @YES
            } mutableCopy];
            if (step == 2) {
                NSString *file = [cfg[@"local"] stringByAppendingPathComponent:@"leaf"];
                [@"changed" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            [client transferRsync:cfg requestID:@"copy"];
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) || reply[@"error"]) {
                fprintf(stderr, "rsync fixture phase %d: %s\n", step, [reply[@"error"] UTF8String] ?: "timeout");
                return 5;
            }
        }
        NSString *src = [root stringByAppendingPathComponent:@"input/leaf"],
                 *dst = [root stringByAppendingPathComponent:@"single"];
        NSMutableDictionary *single = [@{
            @"local" : src,
            @"remote" : @"/single",
            @"binary" : binary,
            @"server" : @"/fixture/rsync",
            @"upload" : @YES,
            @"policy" : @"overwrite",
            @"compress" : @NO
        } mutableCopy];
        BOOL (^transfer)(void) = ^BOOL {
          [client transferRsync:single requestID:@"single"];
          return !dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) &&
                 !reply[@"error"];
        };
        if (!transfer())
            return 9;
        NSData *original = [NSData dataWithContentsOfFile:src],
               *marker = [@"existing" dataUsingEncoding:NSUTF8StringEncoding];
        [marker writeToFile:dst atomically:YES];
        single[@"local"] = dst;
        single[@"upload"] = @NO;
        single[@"policy"] = @"skip";
        if (!transfer() || ![marker isEqual:[NSData dataWithContentsOfFile:dst]])
            return 10;
        single[@"policy"] = @"ask";
        stopOnConflict = YES;
        if (transfer() || ![marker isEqual:[NSData dataWithContentsOfFile:dst]])
            return 11;
        single[@"policy"] = @"overwrite";
        stopOnConflict = NO;
        if (!transfer() || ![original isEqual:[NSData dataWithContentsOfFile:dst]])
            return 12;
        single[@"server"] = @"/fixture/missing";
        if (transfer() || ![reply[@"startup"] boolValue])
            return 13;
        [client disconnect];
        NSData *source = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"input/leaf"]];
        BOOL equal =
            [source isEqual:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"output/leaf"]]];
        equal =
            equal &&
            [sentinel
                isEqual:[NSData
                            dataWithContentsOfFile:[root stringByAppendingPathComponent:@"output/nested/二.txt"]]] &&
            [NSFileManager.defaultManager
                fileExistsAtPath:[root stringByAppendingPathComponent:@"output/nested/empty"]];
        if (sandbox)
            [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        return conflicts == 1 && equal ? 0 : 6;
    }
}
