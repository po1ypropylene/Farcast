#import "SSHClient.h"
#import <Foundation/Foundation.h>

static NSLock *outputLock;
static void emit(NSDictionary *event) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    [outputLock lock];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    [outputLock unlock];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "probe") == 0)
            return [FCSSHClient verifyForwardingListener] ? 0 : 1;
        outputLock = [NSLock new];
        char *line = NULL;
        size_t capacity = 0;
        if (getline(&line, &capacity, stdin) < 0)
            return 1;
        NSDictionary *configuration = [NSJSONSerialization
            JSONObjectWithData:[[@(line) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]
                                   dataUsingEncoding:NSUTF8StringEncoding]
                       options:0
                         error:nil];
        NSString *root = @(argv[2]);
        NSString *pin = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"fingerprint"]
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        FCSSHClient *client = [FCSSHClient new];
        client.forwardingRules = configuration[@"rules"];
        client.tunnelPort = [configuration[@"tunnelPort"] integerValue];
        client.tunnelToken = configuration[@"tunnelToken"];
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        client.onTrust = ^BOOL(NSString *fingerprint, NSString *details) {
          return [pin isEqual:fingerprint];
        };
        client.onStatus = ^(NSString *state, NSString *message) {
          emit(@{
              @"event" : @"status",
              @"state" : state,
              @"stage" : [message localizedCaseInsensitiveContainsString:@"tunnel"] ? @"tunnel" : @"ssh"
          });
          if ([state isEqual:@"disconnected"] || [state isEqual:@"failed"])
              dispatch_semaphore_signal(stopped);
        };
        client.onTerminalAvailability = ^(BOOL available) {
          emit(@{@"event" : @"terminalAvailable", @"value" : @(available)});
        };
        client.onFileAvailability = ^(BOOL available) {
          emit(@{@"event" : @"filesAvailable", @"value" : @(available)});
        };
        client.onForwarding =
            ^(NSString *identifier, NSString *state, NSInteger port, NSInteger count, NSString *message) {
              emit(@{
                  @"event" : @"rule",
                  @"id" : identifier,
                  @"state" : state,
                  @"port" : @(port),
                  @"connections" : @(count),
                  @"message" : message
              });
            };
        NSMutableData *terminal = [NSMutableData new];
        client.onData = ^(NSData *bytes) {
          [terminal appendData:bytes];
          if ([[[NSString alloc] initWithData:terminal
                                     encoding:NSUTF8StringEncoding] containsString:@"tunnel-terminal-marker"]) {
              emit(@{@"event" : @"terminal"});
              [terminal setLength:0];
          }
        };
        client.onFiles = ^(NSString *identifier, NSDictionary *result, NSString *error) {
          emit(@{@"event" : @"file", @"id" : identifier, @"ok" : @(error == nil)});
        };
        client.onFileProgress = ^(NSString *identifier, unsigned long long bytes, unsigned long long total) {
          if (bytes)
              emit(@{@"event" : @"progress", @"id" : identifier});
        };
        client.onFileConflict = ^(NSString *token, NSString *name) {
          emit(@{@"event" : @"conflict", @"token" : token});
        };
        [client connectHost:@"127.0.0.1"
                       port:atoi(argv[1])
                   username:@"fixture"
                   password:@"fixture-password"
                 privateKey:nil
             authentication:@"password"];
        while (getline(&line, &capacity, stdin) > 0) {
            NSDictionary *command =
                [NSJSONSerialization JSONObjectWithData:[@(line) dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0
                                                  error:nil];
            NSString *operation = command[@"op"];
            if ([operation isEqual:@"stop"])
                [client stopForwarding:command[@"id"]];
            if ([operation isEqual:@"start"])
                [client startForwarding:command[@"id"]];
            if ([operation isEqual:@"update"])
                emit(@{
                    @"event" : @"accepted",
                    @"value" : @([client updateForwarding:command[@"rule"] start:[command[@"start"] boolValue]])
                });
            if ([operation isEqual:@"remove"])
                emit(@{@"event" : @"accepted", @"value" : @([client removeForwarding:command[@"id"]])});
            if ([operation isEqual:@"terminal"])
                [client sendData:[@"tunnel-terminal-marker\n" dataUsingEncoding:NSUTF8StringEncoding]];
            if ([operation isEqual:@"file"])
                [client transferLocalPath:[root stringByAppendingPathComponent:command[@"local"]]
                               remotePath:command[@"remote"]
                                   upload:[command[@"upload"] boolValue]
                                requestID:command[@"id"]];
            if ([operation isEqual:@"conflict"])
                [client resolveFileConflict:command[@"token"] overwrite:YES];
            if ([operation isEqual:@"cancelFiles"])
                [client cancelFiles];
            if ([operation isEqual:@"list"])
                [client listDirectory:@"." requestID:command[@"id"]];
            if ([operation isEqual:@"quit"])
                break;
        }
        free(line);
        [client disconnect];
        if (dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)))
            return 2;
        dispatch_semaphore_t drained = dispatch_semaphore_create(0);
        [FCSSHClient whenAllDisconnected:^{
          dispatch_semaphore_signal(drained);
        }];
        if (dispatch_semaphore_wait(drained, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)))
            return 3;
        emit(@{@"event" : @"drained"});
    }
    return 0;
}
