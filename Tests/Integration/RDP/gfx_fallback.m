#import "RDPClient.h"
#import <Foundation/Foundation.h>
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3)
            return 2;
        BOOL cancel = strcmp(argv[2], "cancel") == 0;
        FCRDPClient *client = [FCRDPClient new];
        client.experimentalGraphics = YES;
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        __block NSUInteger connected = 0;
        __block BOOL fallback = NO, pixels = NO;
        __weak FCRDPClient *weakClient = client;
        client.onTrust = ^BOOL(NSString *fingerprint, NSString *details) {
          return YES;
        }; // Owned fixture certificate only.
        client.onStatus = ^(NSString *state, NSString *message) {
          if ([state isEqualToString:@"connected"]) {
              connected++;
              if (cancel)
                  [weakClient disconnect];
          }
          if ([message containsString:@"retrying once"])
              fallback = YES;
        };
        client.onFrameRegion = ^(NSData *data, NSInteger desktopWidth, NSInteger desktopHeight, NSInteger x,
                                 NSInteger y, NSInteger width, NSInteger height) {
          pixels =
              x == 0 && y == 0 && width == desktopWidth && height == desktopHeight && data.length == width * height * 4;
          [weakClient disconnect];
        };
        client.onStopped = ^(BOOL retryable) {
          dispatch_semaphore_signal(stopped);
        };
        [client connectHost:@"127.0.0.1"
                       port:atoi(argv[1])
                   username:@"fixture"
                     domain:@""
                   password:@"fixture"
                      width:640
                     height:480
                      scale:100
                  clipboard:NO
              audioPlayback:NO];
        if (dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)))
            return 3;
        if (cancel ? (connected != 1 || fallback) : (connected != 2 || !fallback || !pixels)) {
            fprintf(stderr, "FAIL fallback counts connected=%lu fallback=%d pixels=%d\n", (unsigned long)connected,
                    fallback, pixels);
            return 4;
        }
        puts(cancel ? "PASS disconnect cancels pending GFX fallback"
                    : "PASS frame-less GFX attempt retires and retries once with compatible graphics and a complete "
                      "initial patch");
    }
}
