#import "RDPClient.h"
#import "SSHClient.h"
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

// No connection details, remote terminal data or library diagnostics reach
// stdout. Each connection authenticates and opens a shell/desktop or reads
// SFTP directory metadata without printing names, then disconnects.
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2)
            return 2;
        BOOL configured = NO, sftp = NO, rdpOnly = NO, fullScreen = NO, retina = NO;
        NSInteger selectedServer = 0;
        for (int argument = 2; argument < argc; argument++) {
            if (!strcmp(argv[argument], "--configured"))
                configured = YES;
            else if (!strcmp(argv[argument], "--sftp"))
                sftp = YES;
            else if (!strcmp(argv[argument], "--rdp-only"))
                rdpOnly = YES;
            else if (!strcmp(argv[argument], "--rdp-full-screen"))
                fullScreen = rdpOnly = YES;
            else if (!strcmp(argv[argument], "--rdp-retina"))
                retina = YES;
            else if (!strncmp(argv[argument], "--server=", 9)) {
                char *end;
                selectedServer = strtol(argv[argument] + 9, &end, 10);
                if (*end || selectedServer < 1 || selectedServer > 100)
                    return 2;
            } else
                return 2;
        }
        if ((retina && !fullScreen) || (sftp && rdpOnly))
            return 2;
        NSString *pinOverride = NSProcessInfo.processInfo.environment[@"FARCAST_TEST_SSH_PIN"];
        if (pinOverride && (!selectedServer || ![pinOverride hasPrefix:@"SHA256:"])) {
            puts("FAIL: a trusted SSH pin override requires one selected server.");
            return 2;
        }
        setbuf(stdout, NULL);
        struct stat attributes;
        if (lstat(argv[1], &attributes) != 0 || !S_ISREG(attributes.st_mode) || attributes.st_uid != getuid() ||
            (attributes.st_mode & 077) != 0 || attributes.st_size > 1048576) {
            puts("FAIL: credentials file must be owned by you, regular, at most 1 "
                 "MB, and mode 600.");
            return 2;
        }
        NSData *bytes = [NSData dataWithContentsOfFile:@(argv[1])];
        NSDictionary *document = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
        if (![document isKindOfClass:NSDictionary.class] || ![document[@"schemaVersion"] isEqual:@1] ||
            ![document[@"servers"] isKindOfClass:NSArray.class] || [document[@"servers"] count] > 100) {
            puts("FAIL: invalid local test-server document.");
            return 2;
        }
        int index = 0, failures = 0, tested = 0;
        NSMutableSet *ids = [NSMutableSet new];
        for (id item in document[@"servers"]) {
            index++;
            if (selectedServer && selectedServer != index)
                continue;
            if (![item isKindOfClass:NSDictionary.class] || ![item[@"enabled"] isKindOfClass:NSNumber.class]) {
                puts("FAIL: invalid server entry.");
                return 2;
            }
            if (rdpOnly && ![item[@"protocol"] isEqual:@"RDP"])
                continue;
            if (![item[@"enabled"] boolValue]) {
                if (!configured || ![item[@"host"] isKindOfClass:NSString.class] || ![item[@"host"] length] ||
                    ![item[@"username"] isKindOfClass:NSString.class] || ![item[@"username"] length])
                    continue;
            }
            tested++;
            NSString *kind = item[@"protocol"], *host = item[@"host"], *username = item[@"username"];
            NSString *password = item[@"password"] ?: @"", *domain = item[@"domain"] ?: @"";
            NSString *pin = item[@"expectedFingerprint"] ?: @"";
            NSUUID *identifier =
                [item[@"id"] isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:item[@"id"]] : nil;
            id portValue = item[@"port"];
            BOOL ssh = [kind isKindOfClass:NSString.class] && [kind isEqualToString:@"SSH"];
            BOOL rdp = [kind isKindOfClass:NSString.class] && [kind isEqualToString:@"RDP"];
            if (ssh && pinOverride)
                pin = pinOverride;
            BOOL valid =
                identifier && ![ids containsObject:identifier] && (ssh || rdp) && [host isKindOfClass:NSString.class] &&
                host.length > 0 &&
                [host rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound &&
                ![host containsString:@"/"] && [username isKindOfClass:NSString.class] && username.length > 0 &&
                [password isKindOfClass:NSString.class] && [domain isKindOfClass:NSString.class] &&
                [pin isKindOfClass:NSString.class] && [portValue isKindOfClass:NSNumber.class] &&
                [portValue integerValue] >= 1 && [portValue integerValue] <= 65535 &&
                (!ssh || [pin hasPrefix:@"SHA256:"]) && (!sftp || ssh);
            if (!valid) {
                printf("FAIL server %d: invalid entry or missing SSH fingerprint.\n", index);
                failures++;
                continue;
            }
            [ids addObject:identifier];
            NSInteger port = [portValue integerValue];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block BOOL connected = NO, failed = NO, frame = NO, filesReady = NO, filesRequested = NO;
            __block BOOL terminalAvailable = YES;
            __block NSString *stage = @"connection";
            BOOL (^trust)(NSString *, NSString *) = ^BOOL(NSString *fingerprint, NSString *details) {
              return pin.length > 0 && [fingerprint isEqualToString:pin];
            };
            FCSSHClient *sshClient = ssh ? [FCSSHClient new] : nil;
            FCRDPClient *rdpClient = rdp ? [FCRDPClient new] : nil;
            __weak FCSSHClient *weakSSH = sshClient;
            __weak FCRDPClient *weakRDP = rdpClient;
            void (^status)(NSString *, NSString *) = ^(NSString *state, NSString *message) {
              if ([state isEqualToString:@"verifying"])
                  stage = @"identity";
              if ([state isEqualToString:@"authenticating"])
                  stage = @"authentication";
              if ([state isEqualToString:@"connected"]) {
                  connected = YES;
                  stage = sftp ? @"SFTP availability" : @"session";
                  if (sftp && !filesRequested) {
                      filesRequested = YES;
                      [weakSSH listDirectory:@"." requestID:@"probe"];
                  } else if (ssh && !sftp)
                      [weakSSH disconnect];
              }
              if ([state isEqualToString:@"failed"]) {
                  failed = YES;
                  if ([message containsString:@"ERRCONNECT_ACTIVATION_TIMEOUT"])
                      stage = @"desktop activation";
              }
              if ([state isEqualToString:@"failed"] || [state isEqualToString:@"disconnected"])
                  dispatch_semaphore_signal(done);
            };
            if (ssh) {
                sshClient.onTrust = trust;
                sshClient.onStatus = status;
                sshClient.onData = ^(NSData *data) {
                };
                sshClient.onPrompt = ^NSString *(NSString *prompt, BOOL echo) {
                  return nil;
                };
                sshClient.onTerminalAvailability = ^(BOOL available) {
                  terminalAvailable = available;
                };
                sshClient.onFiles = ^(NSString *request, NSDictionary *result, NSString *error) {
                  filesReady = !error && [result[@"entries"] isKindOfClass:NSArray.class];
                  // Allow an accepted-but-exiting forced shell to report its capability.
                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                   [weakSSH disconnect];
                                 });
                };
                [sshClient connectHost:host
                                  port:port
                              username:username
                              password:password
                            privateKey:nil
                        authentication:@"password"];
            } else {
                NSInteger requestedWidth = 1024, requestedHeight = 768, requestedScale = 100;
                if (fullScreen) {
                    [NSApplication sharedApplication];
                    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
                    double factor = retina ? screen.backingScaleFactor : 1;
                    requestedWidth = (NSInteger)(floor(screen.frame.size.width * factor / 2) * 2);
                    requestedHeight = (NSInteger)floor(screen.frame.size.height * factor);
                    requestedScale = (NSInteger)llround(factor * 100);
                    rdpClient.monitorDefinitions = @[ @{
                        @"x" : @0,
                        @"y" : @0,
                        @"width" : @(requestedWidth),
                        @"height" : @(requestedHeight),
                        @"primary" : @1,
                        @"scale" : @(requestedScale),
                        @"physicalWidth" : @0,
                        @"physicalHeight" : @0,
                        @"orientation" : @0
                    } ];
                }
                rdpClient.onTrust = trust;
                rdpClient.onStatus = status;
                rdpClient.onFrame = ^(NSData *pixels, NSInteger width, NSInteger height, NSInteger stride) {
                  frame = width > 0 && height > 0 && stride >= width * 4 && pixels.length == stride * height;
                  if (frame && fullScreen && (width != requestedWidth || height != requestedHeight)) {
                      frame = NO;
                      failed = YES;
                      stage = @"full-screen geometry";
                      [weakRDP disconnect];
                      return;
                  }
                  if (frame) {
                      // Empty allocation/paint callbacks do not prove a usable desktop.
                      const uint8_t *data = pixels.bytes;
                      BOOL visible = NO;
                      for (NSInteger y = 0; y < height && !visible; y++) {
                          for (NSInteger x = 0; x < width; x++) {
                              const uint8_t *pixel = data + y * stride + x * 4;
                              if (pixel[0] || pixel[1] || pixel[2]) {
                                  visible = YES;
                                  break;
                              }
                          }
                      }
                      frame = visible;
                  }
                  if (frame)
                      [weakRDP disconnect];
                };
                [rdpClient connectHost:host
                                  port:port
                              username:username
                                domain:domain
                              password:password
                                 width:requestedWidth
                                height:requestedHeight
                                 scale:requestedScale
                             clipboard:NO
                         audioPlayback:NO];
            }
            BOOL timeout = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC)) != 0;
            [sshClient disconnect];
            [rdpClient disconnect];
            BOOL pass = !timeout && connected && !failed && (ssh || frame) && (!sftp || filesReady);
            NSString *detail =
                pass ? (sftp ? (terminalAvailable ? @"authenticated SFTP directory opened"
                                                  : @"authenticated SFTP directory opened; file transfer only")
                             : (ssh ? @"authenticated session opened" : @"authenticated desktop pixels received"))
                     : [stage stringByAppendingString:@" check failed or timed out"];
            printf("%s server %d (%s): %s\n", pass ? "PASS" : "FAIL", index, ssh ? "SSH" : "RDP", detail.UTF8String);
            if (!pass)
                failures++;
        }
        if (!tested && selectedServer) {
            puts("FAIL: selected server is missing, disabled or unconfigured.");
            return 2;
        }
        if (!tested)
            puts("SKIP: no enabled real servers. Fill the local file before testing.");
        return failures ? 1 : 0;
    }
}
