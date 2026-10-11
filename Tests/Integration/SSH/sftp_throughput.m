#import "SSHClient.h"
#import <Foundation/Foundation.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 4)
            return 2;
        NSString *root = @(argv[2]);
        NSString *pin = [NSString stringWithContentsOfFile:@(argv[3]) encoding:NSUTF8StringEncoding error:nil];
        NSString *path = [root stringByAppendingPathComponent:@"throughput-source"];
        NSMutableData *source = [NSMutableData dataWithLength:16 * 1024 * 1024];
        uint8_t *bytes = source.mutableBytes;
        uint32_t state = 0x13579bdf;
        for (NSUInteger i = 0; i < source.length; i++) {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            bytes[i] = state & 255;
        }
        [source writeToFile:path atomically:YES];
        FCSSHClient *client = [FCSSHClient new];
        [client setTerminalVisible:NO];
        dispatch_semaphore_t ready = dispatch_semaphore_create(0), done = dispatch_semaphore_create(0);
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block BOOL pass = NO;
        client.onTrust = ^BOOL(NSString *fingerprint, NSString *details) {
          return [pin isEqual:fingerprint];
        };
        client.onStatus = ^(NSString *state, NSString *message) {
          if ([state isEqual:@"connected"])
              dispatch_semaphore_signal(ready);
          if ([state isEqual:@"disconnected"] || [state isEqual:@"failed"])
              dispatch_semaphore_signal(finished);
        };
        client.onFiles = ^(NSString *id, NSDictionary *reply, NSString *error) {
          pass = error == nil && [reply[@"bytes"] unsignedLongLongValue] == 16 * 1024 * 1024;
          dispatch_semaphore_signal(done);
        };
        [client connectHost:@"127.0.0.1"
                       port:atoi(argv[1])
                   username:@"fixture"
                   password:@"fixture-password"
                 privateKey:nil
             authentication:@"password"];
        if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)))
            return 1;
        double start = NSDate.timeIntervalSinceReferenceDate;
        [client transferLocalPath:path remotePath:@"/throughput.bin" upload:YES requestID:@"speed"];
        BOOL completed = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0;
        double seconds = NSDate.timeIntervalSinceReferenceDate - start;
        if (completed && pass)
            printf("%.3f\n", 16.0 / seconds);
        [client disconnect];
        dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        return completed && pass ? 0 : 1;
    }
}
