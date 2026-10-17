#import "RDPClient.h"
#import <Foundation/Foundation.h>
#import <signal.h>
#import <stdatomic.h>

// Owned loopback TLS peer only. Block a worker callback to exercise cancellation
// without relying on an actual deadlock or touching a user's desktop.
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3)
            return 2;
        NSInteger port = atoi(argv[1]);
        pid_t server = atoi(argv[2]);
        for (NSString *mode in @[ @"idle", @"stalled", @"lost" ]) {
            FCRDPClient *client = [FCRDPClient new];
            dispatch_semaphore_t connected = dispatch_semaphore_create(0);
            dispatch_semaphore_t gate = dispatch_semaphore_create(0);
            dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
            __block BOOL retryable = NO;
            __block BOOL sawStale = NO;
            client.onTrust = ^BOOL(NSString *fingerprint, NSString *details) {
              return YES; // Disposable certificate from this test's loopback peer.
            };
            client.onStatus = ^(NSString *state, NSString *message) {
              if ([state isEqualToString:@"stale"])
                  sawStale = YES;
              if ([state isEqualToString:@"connected"]) {
                  dispatch_semaphore_signal(connected);
                  if ([mode isEqualToString:@"stalled"])
                      dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC));
              }
            };
            client.onStopped = ^(BOOL canRetry) {
              retryable = canRetry;
              dispatch_semaphore_signal(stopped);
            };
            [client connectHost:@"127.0.0.1"
                           port:port
                       username:@"fixture"
                         domain:@""
                       password:@"fixture"
                          width:640
                         height:480
                          scale:100
                      clipboard:NO
                  audioPlayback:NO];
            if (dispatch_semaphore_wait(connected, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)))
                return 3;
            if ([mode isEqualToString:@"idle"]) {
                for (int second = 0; second < 33; second++) {
                    [NSThread sleepForTimeInterval:1];
                    if (!client.responsive)
                        return 4;
                }
                [client disconnect];
            } else if ([mode isEqualToString:@"stalled"]) {
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:35];
                while (client.responsive && deadline.timeIntervalSinceNow > 0)
                    [NSThread sleepForTimeInterval:0.1];
                if (client.responsive)
                    return 5;
                [client interruptStalledConnection];
                dispatch_semaphore_signal(gate);
            } else {
                if (server <= 1 || kill(server, SIGTERM) != 0)
                    return 6;
            }
            if (dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)))
                return 7;
            if ([mode isEqualToString:@"idle"] ? retryable : !retryable)
                return 8;
            if ([mode isEqualToString:@"stalled"] && !sawStale)
                return 9;
            printf("PASS RDP %s worker health, termination status and retry classification\n", mode.UTF8String);
        }
    }
    return 0;
}
