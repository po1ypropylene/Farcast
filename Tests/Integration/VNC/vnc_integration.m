#import "../../../Farcast/Native/VNC/VNCClient.h"
#import <Foundation/Foundation.h>
#import <openssl/sha.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4)
            return 2;
        NSInteger port = atoi(argv[1]);
        NSString *mode = @(argv[2]), *root = @(argv[3]);
        BOOL shouldFail =
            [@[ @"wrong", @"bounds", @"encoding", @"oversized", @"unsupported", @"tlsreject", @"tlsanonymous" ]
                containsObject:mode];
        FCVNCClient *client = [FCVNCClient new];
        dispatch_semaphore_t frames = dispatch_semaphore_create(0), failed = dispatch_semaphore_create(0);
        __block BOOL rejected = NO, trusted = NO;
        __block NSInteger received = 0;
        client.onAuthenticationRejected = ^{
          rejected = YES;
        };
        client.onTrust = ^BOOL(NSString *pin, NSString *details) {
          NSData *der = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"cert.der"]];
          unsigned char digest[32];
          SHA256(der.bytes, der.length, digest);
          NSString *expected = [@"SHA256:"
              stringByAppendingString:[[[NSData dataWithBytes:digest length:32] base64EncodedStringWithOptions:0]
                                          stringByReplacingOccurrencesOfString:@"="
                                                                    withString:@""]];
          NSCAssert([pin isEqual:expected], @"TLS identity must match the owned certificate");
          trusted = YES;
          return ![mode isEqual:@"tlsreject"];
        };
        client.onStatus = ^(NSString *state, NSString *message) {
          if ([state isEqual:@"failed"])
              dispatch_semaphore_signal(failed);
        };
        __weak FCVNCClient *weakClient = client;
        client.onFrame = ^(NSData *data, NSInteger w, NSInteger h, NSInteger stride) {
          const unsigned char *p = data.bytes;
          if (w == 32) {
              NSCAssert(h == 24 && stride == 128, @"Initial geometry");
              NSCAssert(p[(2 * w + 2) * 4] == 1, @"Overlapping CopyRect");
              NSCAssert(p[(1 * w + 17) * 4] == 200 && p[(3 * w + 19) * 4] == 40, @"Hextile background/subrectangle");
              NSCAssert(p[(16 * w) * 4] == 70 && p[(16 * w + 8) * 4] == 90, @"Persistent zlib stream");
          } else {
              NSCAssert(w == 40 && h == 30 && data.length == 4800 && p[0] == 11 && p[4798] == 33,
                        @"Resized raw framebuffer");
          }
          if (++received == 2) {
              // Queue on the owner worker so draining cannot interleave. Keep
              // button transitions at their original coordinates, coalesce only motion.
              [weakClient sendPointerMask:1 x:7 y:8];
              [weakClient sendPointerMask:1 x:8 y:8];
              [weakClient sendPointerMask:1 x:9 y:8];
              [weakClient sendPointerMask:0 x:9 y:8];
              [weakClient sendPointerMask:0 x:10 y:8];
              [weakClient sendPointerMask:0 x:11 y:8];
              [weakClient sendPointerMask:8 x:11 y:8];
              [weakClient sendPointerMask:0 x:11 y:8];
              dispatch_semaphore_signal(frames);
          }
        };
        [client connectHost:@"127.0.0.1" port:port username:@"fixture" password:@"fixture-password"];
        dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC);
        if (shouldFail) {
            NSCAssert(dispatch_semaphore_wait(failed, deadline) == 0, @"Invalid/unsupported peer must fail promptly");
            NSCAssert(![mode isEqual:@"wrong"] || rejected, @"Authentication rejection signal");
        } else {
            NSCAssert(dispatch_semaphore_wait(frames, deadline) == 0, @"Frames were not decoded");
            NSCAssert(![mode hasPrefix:@"tls"] || trusted, @"TLS must check original server identity");
            NSCAssert(![client typeText:@"unsafe\x1b"], @"Control text must be refused");
            NSCAssert(![client typeText:[@"a" stringByPaddingToLength:16385 withString:@"a" startingAtIndex:0]],
                      @"Typing quota");
            NSCAssert([client typeText:@"Aé中😀\t\r\nB"], @"Unicode text accepted");
            [NSThread sleepForTimeInterval:0.2];
            [client sendPointerMask:1 x:7 y:8];
            [client sendPointerMask:0 x:7 y:8];
            [client sendControlAltDelete];
            [NSThread sleepForTimeInterval:0.2];
            NSCAssert([client typeText:[@"z" stringByPaddingToLength:1000 withString:@"z" startingAtIndex:0]],
                      @"Cancellation text");
            [NSThread sleepForTimeInterval:0.05];
            [client cancelTyping];
            [NSThread sleepForTimeInterval:0.05];
        }
        [client disconnect];
        dispatch_semaphore_t drained = dispatch_semaphore_create(0);
        [FCVNCClient whenAllDisconnected:^{
          dispatch_semaphore_signal(drained);
        }];
        NSCAssert(dispatch_semaphore_wait(drained, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
                  @"Worker shutdown");
        printf("PASS VNC %s\n", mode.UTF8String);
    }
    return 0;
}
