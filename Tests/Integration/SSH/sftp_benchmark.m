#import "SSHClient.h"
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <time.h>

static double timer(clockid_t clock) {
    struct timespec value;
    clock_gettime(clock, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}
static NSData *digest(NSString *path) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!file)
        return nil;
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    NSData *chunk;
    while ((chunk = [file readDataOfLength:256 * 1024]).length)
        CC_SHA256_Update(&hash, chunk.bytes, (CC_LONG)chunk.length);
    [file closeFile];
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(bytes, &hash);
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 7)
            return 2;
        NSString *root = [@(argv[2]) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *pin = [NSString stringWithContentsOfFile:@(argv[3]) encoding:NSUTF8StringEncoding error:nil];
        NSUInteger count = strtoul(argv[4], NULL, 10), largeMiB = strtoul(argv[5], NULL, 10);
        if (!count || count > 5000 || !largeMiB || largeMiB > 1024)
            return 2;
        NSFileManager *files = NSFileManager.defaultManager;
        NSString *small = [root stringByAppendingPathComponent:@"small"];
        [files createDirectoryAtPath:small withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableData *pattern = [NSMutableData dataWithLength:1024 * 1024];
        uint32_t state = 0x13579bdf;
        for (NSUInteger i = 0; i < pattern.length; i++) {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            ((uint8_t *)pattern.mutableBytes)[i] = state & 255;
        }
        for (NSUInteger i = 0; i < count; i++) {
            NSString *path = [small stringByAppendingPathComponent:[NSString stringWithFormat:@"%05lu.bin", i]];
            [[pattern subdataWithRange:NSMakeRange(0, (1 + i % 50) * 1024)] writeToFile:path atomically:NO];
        }
        NSString *large = [root stringByAppendingPathComponent:@"large.bin"];
        [files createFileAtPath:large contents:nil attributes:nil];
        NSFileHandle *writer = [NSFileHandle fileHandleForWritingAtPath:large];
        for (NSUInteger i = 0; i < largeMiB; i++)
            [writer writeData:pattern];
        [writer closeFile];
        FCSSHClient *client = [FCSSHClient new];
        if ([client respondsToSelector:@selector(setTerminalVisible:)])
            [client setTerminalVisible:NO];
        dispatch_semaphore_t ready = dispatch_semaphore_create(0), done = dispatch_semaphore_create(0);
        __block BOOL passed = NO, connected = NO;
        client.onTrust = ^BOOL(NSString *fingerprint, NSString *details) {
          return [pin isEqual:fingerprint];
        };
        client.onStatus = ^(NSString *status, NSString *message) {
          if ([status isEqual:@"connected"]) {
              connected = YES;
              dispatch_semaphore_signal(ready);
          } else if ([status isEqual:@"failed"]) {
              passed = NO;
              dispatch_semaphore_signal(ready);
              dispatch_semaphore_signal(done);
          }
        };
        client.onFiles = ^(NSString *id, NSDictionary *reply, NSString *error) {
          passed = error == nil;
          dispatch_semaphore_signal(done);
        };
        // Match the app's conflict-enabled path; these fresh targets must not conflict.
        __weak FCSSHClient *weakClient = client;
        client.onFileConflict = ^(NSString *token, NSString *name) {
          [weakClient resolveFileConflict:token overwrite:NO];
        };
        [client connectHost:@"127.0.0.1"
                       port:atoi(argv[1])
                   username:@"fixture"
                   password:@"fixture-password"
                 privateKey:nil
             authentication:@"password"];
        if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) || !connected)
            return 1;
        BOOL allPassed = YES;
        NSMutableArray *measurements = [NSMutableArray new];
        for (NSString *workload in @[ @"large", @"small" ]) {
            for (NSNumber *uploadValue in @[ @YES, @NO ]) {
                BOOL upload = uploadValue.boolValue;
                NSString *source = [workload isEqual:@"large"] ? large : small;
                NSString *remote = [workload isEqual:@"large"] ? @"/benchmark-large.bin" : @"/benchmark-small";
                NSString *target =
                    upload ? source : [root stringByAppendingPathComponent:[workload stringByAppendingString:@"-copy"]];
                passed = NO;
                double start = timer(CLOCK_MONOTONIC), cpu = timer(CLOCK_PROCESS_CPUTIME_ID);
                if ([workload isEqual:@"large"])
                    [client transferLocalPath:target remotePath:remote upload:upload requestID:@"benchmark"];
                else
                    [client fileOperation:upload ? @"uploadTree" : @"downloadTree"
                                   source:upload ? source : remote
                              destination:upload ? remote : target
                                     move:NO
                                requestID:@"benchmark"];
                BOOL completed =
                    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_SEC)) == 0;
                double seconds = timer(CLOCK_MONOTONIC) - start, cpuSeconds = timer(CLOCK_PROCESS_CPUTIME_ID) - cpu;
                allPassed &= completed && passed;
                if (!allPassed)
                    break;
                if (!upload) {
                    if ([workload isEqual:@"large"])
                        allPassed &= [digest(source) isEqual:digest(target)];
                    else {
                        for (NSString *name in [files contentsOfDirectoryAtPath:source error:nil])
                            allPassed &= [digest([source stringByAppendingPathComponent:name])
                                isEqual:digest([target stringByAppendingPathComponent:name])];
                    }
                }
                [measurements addObject:@{
                    @"workload" : workload,
                    @"direction" : upload ? @"upload" : @"download",
                    @"rtt_ms" : @(strtoul(argv[6], NULL, 10)),
                    @"files" : @([workload isEqual:@"small"] ? count : 1),
                    @"large_mib" : @(largeMiB),
                    @"seconds" : @(seconds),
                    @"cpu_seconds" : @(cpuSeconds)
                }];
                // Publish both directions only after the round-trip hashes match.
                if (!upload && allPassed) {
                    for (NSDictionary *row in measurements) {
                        NSMutableDictionary *verified = row.mutableCopy;
                        verified[@"verified"] = @YES;
                        NSData *json = [NSJSONSerialization dataWithJSONObject:verified options:0 error:nil];
                        printf("%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
                    }
                    [measurements removeAllObjects];
                    fflush(stdout);
                }
            }
            if (!allPassed)
                break;
        }
        [client disconnect];
        dispatch_semaphore_t shutdown = dispatch_semaphore_create(0);
        [FCSSHClient whenAllDisconnected:^{
          dispatch_semaphore_signal(shutdown);
        }];
        dispatch_semaphore_wait(shutdown, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        [files removeItemAtPath:root error:nil];
        return allPassed ? 0 : 1;
    }
}
