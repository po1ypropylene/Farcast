#import "RDPClient.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <winpr/synch.h>

static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2)
            return 2;
        FCRDPClient *client = [FCRDPClient new];
        dispatch_semaphore_t ready = dispatch_semaphore_create(0), sample = dispatch_semaphore_create(0),
                             done = dispatch_semaphore_create(0);
        double *delays = calloc(160, sizeof(double));
        __block NSUInteger count = 0;
        __block BOOL connected = NO;
        client.onTrust = ^BOOL(NSString *fingerprint, NSString *details) {
          return YES;
        }; // Owned fixture certificate.
        client.onStatus = ^(NSString *status, NSString *message) {
          if ([status isEqualToString:@"connected"]) {
              connected = YES;
              dispatch_semaphore_signal(ready);
          }
        };
        client.onFrame = ^(NSData *data, NSInteger w, NSInteger h, NSInteger stride) {
        };
        client.onInputQueueDelay = ^(double milliseconds) {
          if (count < 160)
              delays[count++] = milliseconds;
          dispatch_semaphore_signal(sample);
        };
        client.onStopped = ^(BOOL retryable) {
          dispatch_semaphore_signal(done);
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
        if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) || !connected)
            return 3;
        [NSThread sleepForTimeInterval:0.2];
        for (int i = 0; i < 160; i++) {
            [NSThread sleepForTimeInterval:0.001 + (i % 19) * 0.0009];
            [client synchronizeCapsLock:NO];
            if (dispatch_semaphore_wait(sample, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)))
                return 4;
        }
        [client disconnect];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) || count != 160)
            return 5;
        qsort(delays, count, sizeof(double), compare);
        printf("PASS owned TLS input enqueue-to-drain samples=%lu p50=%.3f p95=%.3f p99=%.3fms (not input-to-visual "
               "latency)\n",
               (unsigned long)count, delays[79], delays[151], delays[157]);
        free(delays);
    }
    return 0;
}
