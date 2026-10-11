#import "SSHClient.h"
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <time.h>

// The baseline predates this selector; exercise its existing transport unchanged.
@interface FCSSHClient (LatencyMode)
- (void)setTerminalVisible:(BOOL)visible;
@end
static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static NSData *hash(NSString *path) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!file)
        return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    NSData *data;
    while ((data = [file readDataOfLength:65536]).length)
        CC_SHA256_Update(&context, data.bytes, (CC_LONG)data.length);
    [file closeFile];
    unsigned char result[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(result, &context);
    return [NSData dataWithBytes:result length:sizeof(result)];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 5 && argc != 6)
            return 2;
        BOOL reportOnly = argc == 6;
        NSString *root = [@(argv[2]) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        [files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *source = [root stringByAppendingPathComponent:@"source"];
        NSString *copy = [root stringByAppendingPathComponent:@"copy"];
        NSMutableData *pattern = [NSMutableData dataWithLength:8 * 1024 * 1024];
        uint32_t seed = 1234567;
        for (NSUInteger i = 0; i < pattern.length; i++) {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            ((uint8_t *)pattern.mutableBytes)[i] = seed & 255;
        }
        [pattern writeToFile:source atomically:NO];
        NSString *pin = [NSString stringWithContentsOfFile:@(argv[3]) encoding:NSUTF8StringEncoding error:nil];
        FCSSHClient *client = [FCSSHClient new];
        if ([client respondsToSelector:@selector(setTerminalVisible:)])
            [client setTerminalVisible:YES];
        NSLock *lock = [NSLock new];
        NSMutableDictionary<NSString *, NSNumber *> *pending = [NSMutableDictionary new];
        NSMutableArray<NSNumber *> *latencies = [NSMutableArray new];
        NSMutableString *text = [NSMutableString new];
        dispatch_semaphore_t ready = dispatch_semaphore_create(0), done = dispatch_semaphore_create(0);
        __block BOOL connected = NO, passed = NO, transferring = NO;
        __block NSUInteger trusts = 0;
        __block double measureAfter = 0;
        client.onTrust = ^BOOL(NSString *fingerprint, NSString *details) {
          trusts++;
          return [pin isEqual:fingerprint];
        };
        client.onStatus = ^(NSString *state, NSString *message) {
          if ([state isEqual:@"connected"] || [state isEqual:@"failed"]) {
              connected = [state isEqual:@"connected"];
              dispatch_semaphore_signal(ready);
          }
        };
        client.onData = ^(NSData *data) {
          [lock lock];
          [text appendString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @""];
          NSRange newline;
          while ((newline = [text rangeOfString:@"\n"]).location != NSNotFound) {
              NSString *line = [[text substringToIndex:newline.location]
                  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
              if ([line hasPrefix:@"INPUT:latency-"]) {
                  NSString *token = [line substringFromIndex:6];
                  NSNumber *start = pending[token];
                  if (start) {
                      if (start.doubleValue >= measureAfter)
                          [latencies addObject:@(now() - start.doubleValue)];
                      [pending removeObjectForKey:token];
                  }
              }
              [text deleteCharactersInRange:NSMakeRange(0, newline.location + 1)];
          }
          [lock unlock];
        };
        client.onFileProgress = ^(NSString *id, unsigned long long bytes, unsigned long long total) {
          [lock lock];
          transferring = bytes > 0 && bytes < total;
          [lock unlock];
        };
        client.onFiles = ^(NSString *id, NSDictionary *result, NSString *error) {
          passed = error == nil;
          [lock lock];
          transferring = NO;
          [lock unlock];
          dispatch_semaphore_signal(done);
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
        NSUInteger sequence = 0;
        NSArray *directions = reportOnly ? @[ @YES, @NO ] : @[ @YES, @NO, @YES, @NO ];
        NSUInteger phase = 0;
        for (NSNumber *value in directions) {
            BOOL upload = value.boolValue, switching = phase++ >= 2;
            if (switching)
                [client setTerminalVisible:NO];
            [lock lock];
            [latencies removeAllObjects];
            [pending removeAllObjects];
            [lock unlock];
            passed = NO;
            double start = now(), next = start;
            BOOL switched = !switching;
            [lock lock];
            measureAfter = switching ? INFINITY : 0;
            [lock unlock];
            if (!upload)
                [files removeItemAtPath:copy error:nil];
            [client transferLocalPath:upload ? source : copy
                           remotePath:switching ? @"/latency-switch.bin" : @"/latency.bin"
                               upload:upload
                            requestID:@"latency"];
            BOOL completed = NO;
            while (now() - start < 90) {
                if (!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC))) {
                    completed = YES;
                    break;
                }
                if (!switched && now() - start >= 0.5) {
                    [client setTerminalVisible:YES];
                    switched = YES;
                    // Previously submitted bulk packets must drain on TCP.
                    // Measure steady-state responsiveness after that bounded backlog.
                    [lock lock];
                    measureAfter = now() + 9;
                    [lock unlock];
                }
                [lock lock];
                BOOL send = transferring && now() >= next;
                NSString *token = [NSString stringWithFormat:@"latency-%lu", sequence++];
                if (send)
                    pending[token] = @(now());
                [lock unlock];
                if (send) {
                    [client sendData:[[token stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                    next = now() + 0.25;
                }
            }
            double seconds = now() - start;
            double drain = now() + 2;
            NSUInteger missing;
            do {
                [lock lock];
                missing = pending.count;
                [lock unlock];
                if (!missing)
                    break;
                [NSThread sleepForTimeInterval:0.01];
            } while (now() < drain);
            [lock lock];
            NSArray<NSNumber *> *ordered = [latencies sortedArrayUsingSelector:@selector(compare:)];
            double maximum = ordered.lastObject.doubleValue;
            double p95 = ordered.count ? ordered[(ordered.count - 1) * 95 / 100].doubleValue : 0;
            NSUInteger samples = ordered.count;
            [lock unlock];
            BOOL bytesMatch = upload || [hash(source) isEqual:hash(copy)];
            BOOL responsive = samples >= 16 && !missing && maximum < 1.5;
            allPassed &= completed && passed && bytesMatch && (reportOnly || responsive);
            printf("%s bandwidth-limited-%s-%s: samples=%lu missing=%lu p95=%.3fs max=%.3fs transfer=%.2fs\n",
                   reportOnly ? "MEASURE" : (completed && passed && bytesMatch && responsive ? "PASS" : "FAIL"),
                   upload ? "upload" : "download", switching ? "files-to-split" : "terminal", samples, missing, p95,
                   maximum, seconds);
            fflush(stdout);
            if (!completed || !passed)
                break;
        }
        [client disconnect];
        dispatch_semaphore_t shutdown = dispatch_semaphore_create(0);
        [FCSSHClient whenAllDisconnected:^{
          dispatch_semaphore_signal(shutdown);
        }];
        allPassed &= dispatch_semaphore_wait(shutdown, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0;
        allPassed &= trusts == 1;
        [files removeItemAtPath:root error:nil];
        return allPassed ? 0 : 1;
    }
}
