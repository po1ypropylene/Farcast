#import "SSHClient.h"
#import <Foundation/Foundation.h>
#import <libssh2.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4)
            return 2;
        NSString *mode = @(argv[1]);
        int port = atoi(argv[2]);
        NSString *keyPath = @(argv[3]);
        FCSSHClient *client = [FCSSHClient new];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL trusted = NO, connected = NO, failed = NO, verifiedInput = NO, resized = NO;
        __block int prompts = 0;
        NSMutableString *received = [NSMutableString new];
        __block BOOL sentExit = NO, shellEnded = NO;
        __block BOOL credentialsRejected = NO;
        BOOL overflow = [mode isEqualToString:@"input-overflow"];
        __block BOOL overflowReported = NO;
        __weak FCSSHClient *weakClient = client;
        client.onTerminalAvailability = ^(BOOL available) {
          if (!available && sentExit) {
              shellEnded = YES;
              [weakClient disconnect];
          }
        };
        client.onTrust = ^BOOL(NSString *fingerprint, NSString *details) {
          trusted = YES;
          return ![mode isEqualToString:@"reject"];
        };
        client.onPrompt = ^NSString *(NSString *prompt, BOOL echo) {
          prompts++;
          if ([mode isEqualToString:@"cancel-prompt"])
              return nil;
          return [[prompt lowercaseString] containsString:@"code"] ? @"123456" : @"fixture-password";
        };
        client.onAuthenticationRejected = ^{
          credentialsRejected = YES;
        };
        client.onData = ^(NSData *data) {
          NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
          [received appendString:text];
          if ([received containsString:@"INPUT:integration-check"])
              verifiedInput = YES;
          if ([received containsString:@"RESIZED:120x40"])
              resized = YES;
          if (verifiedInput && resized && !sentExit) {
              sentExit = YES;
              [weakClient sendData:[@"exit\n" dataUsingEncoding:NSUTF8StringEncoding]];
          }
        };
        client.onStatus = ^(NSString *status, NSString *message) {
          if ([status isEqualToString:@"connected"]) {
              connected = YES;
              if (overflow) {
                  [weakClient sendData:[NSMutableData dataWithLength:1024 * 1024 + 1]];
                  return;
              }
              [weakClient resizeColumns:120 rows:40];
              [weakClient sendData:[@"integration-check\n" dataUsingEncoding:NSUTF8StringEncoding]];
              if ([mode isEqualToString:@"cancel"])
                  [weakClient disconnect];
          }
          if ([status isEqualToString:@"failed"]) {
              failed = YES;
              overflowReported = [message containsString:@"SSH input could not keep up"];
              printf("  %s\n", message.UTF8String);
          }
          if ([status isEqualToString:@"failed"] || [status isEqualToString:@"disconnected"])
              dispatch_semaphore_signal(done);
        };
        NSString *authentication = ([mode isEqualToString:@"key"] || [mode isEqualToString:@"ed25519"]) ? @"privateKey"
                                   : [mode isEqualToString:@"interactive"]                              ? @"interactive"
                                                                                                        : @"password";
        NSData *key = ([mode isEqualToString:@"key"] || [mode isEqualToString:@"ed25519"])
                          ? [NSData dataWithContentsOfFile:keyPath]
                          : nil;
        NSString *password = ([mode isEqualToString:@"key"] || [mode isEqualToString:@"ed25519"])
                                 ? @"fixture-passphrase"
                             : [mode hasPrefix:@"bad-"] ? @"wrong"
                                                        : @"fixture-password";
        [client connectHost:@"127.0.0.1"
                       port:port
                   username:@"fixture"
                   password:password
                 privateKey:key
             authentication:authentication];
        BOOL timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0;
        [client disconnect];
        [FCSSHClient whenAllDisconnected:^{
          dispatch_semaphore_signal(done);
        }];
        BOOL drained = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
        BOOL expectedFailure =
            [mode isEqualToString:@"reject"] || [mode hasPrefix:@"bad-"] || [mode isEqualToString:@"key-only"];
        BOOL passed =
            !timedOut && drained && trusted && (expectedFailure ? failed && !connected : connected && !failed);
        if ([mode isEqualToString:@"cancel-prompt"])
            passed = !timedOut && trusted && !failed && !connected && prompts == 1 && !credentialsRejected;
        if (overflow)
            passed = !timedOut && drained && trusted && connected && failed && overflowReported;
        if (!overflow && !expectedFailure && ![mode hasPrefix:@"cancel"])
            passed = passed && verifiedInput && resized && shellEnded;
        if ([mode isEqualToString:@"interactive"])
            passed = passed && prompts == 2;
        else if ([mode isEqualToString:@"keyboard-mfa"] || [mode isEqualToString:@"keyboard-code"] ||
                 [mode isEqualToString:@"keyboard-echo"] || [mode isEqualToString:@"bad-password"])
            passed = passed && prompts == 1;
        else if (![mode isEqualToString:@"cancel-prompt"])
            passed = passed && prompts == 0;
        passed = passed && (credentialsRejected == [mode hasPrefix:@"bad-"]);
        passed = passed && drained;
        printf("%s SSH %s\n", passed ? "PASS" : "FAIL", mode.UTF8String);
        return passed ? 0 : 1;
    }
}
