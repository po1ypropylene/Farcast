#import "RDPClient.h"
#import <Foundation/Foundation.h>
#include <freerdp/freerdp.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#import <math.h>
#import <objc/runtime.h>
#import <winpr/synch.h>

// White-box pause uses the real worker/context on the owned peer; no production
// testing API or user input is needed to exercise FreeRDP's silent-skip condition.
@interface FCRDPClient (KeyboardQueueFixture)
- (BOOL)drainEvents:(void *)context;
@end
static NSUInteger failedInputCalls;
static BOOL failKey(rdpInput *input, UINT16 flags, UINT8 code) {
    failedInputCalls++;
    return FALSE;
}
static BOOL failUnicode(rdpInput *input, UINT16 flags, UINT16 code) {
    failedInputCalls++;
    return FALSE;
}
static BOOL failSynchronize(rdpInput *input, UINT32 flags) {
    failedInputCalls++;
    return FALSE;
}
static BOOL failPointer(rdpInput *input, UINT16 flags, UINT16 x, UINT16 y) {
    failedInputCalls++;
    return FALSE;
}
static freerdp *fixtureInstance(FCRDPClient *client) {
    Ivar field = class_getInstanceVariable(FCRDPClient.class, "_instance");
    freerdp *instance = NULL;
    memcpy(&instance, (const uint8_t *)(__bridge const void *)client + ivar_getOffset(field), sizeof(instance));
    return instance;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3)
            return 2;
        NSString *mode = @(argv[1]);
        NSInteger port = atoi(argv[2]);
        FCRDPClient *client = [FCRDPClient new];
        client.experimentalGraphics = NSProcessInfo.processInfo.environment[@"FARCAST_RDP_EXPERIMENTAL_GFX"].boolValue;
        NSString *tunnelPort = NSProcessInfo.processInfo.environment[@"FARCAST_FIXTURE_TUNNEL_PORT"];
        if (tunnelPort) {
            client.tunnelPort = tunnelPort.integerValue;
            client.tunnelToken = NSProcessInfo.processInfo.environment[@"FARCAST_FIXTURE_TUNNEL_TOKEN"];
        }
        __weak FCRDPClient *weakClient = client;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL trusted = NO, connected = NO, failed = NO, frame = NO;
        BOOL inputOverflowTest = [mode isEqualToString:@"input-overflow"];
        BOOL inputFailureTest = [mode hasPrefix:@"send-failure-"];
        __block BOOL retryable = NO;
        client.onStopped = ^(BOOL canRetry) {
          retryable = canRetry;
        };
        __block BOOL overloadReported = NO;
        BOOL monitorTest = [mode isEqualToString:@"monitors"];
        BOOL retinaTest = [mode isEqualToString:@"retina"];
        __block BOOL monitorLayout = NO, finishing = NO;
        if (monitorTest || retinaTest) {
            client.monitorDefinitions = @[
                @{
                    @"x" : @0,
                    @"y" : @0,
                    @"width" : @1280,
                    @"height" : @720,
                    @"primary" : @1,
                    @"scale" : @200,
                    @"physicalWidth" : @300,
                    @"physicalHeight" : @200,
                    @"orientation" : @0
                },
                @{
                    @"x" : @(-800),
                    @"y" : @0,
                    @"width" : @800,
                    @"height" : @600,
                    @"primary" : @0,
                    @"scale" : @100,
                    @"physicalWidth" : @300,
                    @"physicalHeight" : @200,
                    @"orientation" : @0
                }
            ];
            if (retinaTest)
                client.monitorDefinitions = @[ client.monitorDefinitions.firstObject ];
            client.onMonitorLayout = ^(NSArray<NSDictionary *> *monitors) {
              monitorLayout =
                  monitors.count == 2 && [monitors[0][@"x"] intValue] == 0 && [monitors[1][@"x"] intValue] == -800;
            };
        }
        BOOL clipboardTest = [mode isEqualToString:@"clipboard"];
        BOOL driveTest = [mode hasPrefix:@"drive"];
        __block BOOL drivePassed = NO;
        BOOL fileTest = [mode isEqualToString:@"files"];
        __block BOOL filesPassed = NO;
        __block FCRDPClipboardFileBatch *receivedBatch = nil;
        NSURL *source = nil;
        NSMutableData *fileBytes = [NSMutableData dataWithLength:700123];
        for (NSUInteger i = 0; i < fileBytes.length; i++)
            ((uint8_t *)fileBytes.mutableBytes)[i] = (uint8_t)(i * 31);
        if (fileTest) {
            source = [[NSURL fileURLWithPath:NSProcessInfo.processInfo.environment[@"FARCAST_RDP_CONFIG"]]
                URLByAppendingPathComponent:@"Clipboard folder"];
            [[NSFileManager defaultManager] createDirectoryAtURL:[source URLByAppendingPathComponent:@"Nested"]
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:NULL];
            [fileBytes writeToURL:[source URLByAppendingPathComponent:@"Nested/繁體😀.bin"] atomically:YES];
            [NSData.data writeToURL:[source URLByAppendingPathComponent:@"Empty"] atomically:YES];
            [NSFileManager.defaultManager
                setAttributes:@{NSFileModificationDate : [NSDate dateWithTimeIntervalSince1970:946684800]}
                 ofItemAtPath:[source URLByAppendingPathComponent:@"Nested/繁體😀.bin"].path
                        error:NULL];
            client.onClipboardBatch = ^(FCRDPClipboardFileBatch *batch) {
              receivedBatch = batch;
              // The notification now advertises pending items. Fulfill from a
              // consumer queue so the protocol worker continues receiving PDUs.
              dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [batch requestContents];
                NSArray<NSURL *> *files = batch.files;
                filesPassed =
                    [batch waitUntilReadyWithTimeout:20] && files.count == 1 &&
                    [[NSData dataWithContentsOfURL:[files.firstObject URLByAppendingPathComponent:@"Nested/繁體😀.bin"]]
                        isEqual:fileBytes] &&
                    [NSFileManager.defaultManager
                        fileExistsAtPath:[files.firstObject URLByAppendingPathComponent:@"Empty"].path];
                [weakClient disconnect];
              });
            };
        }
        NSArray<NSString *> *samples = @[ @"Synthetic clipboard 繁體中文 😀\r\nSecond line", @"Updated fixture", @"" ];
        __block NSUInteger clipboardCount = 0;
        NSURL *exportURL = nil;
        if (driveTest) {
            exportURL = [[NSURL fileURLWithPath:NSProcessInfo.processInfo.environment[@"FARCAST_RDP_CONFIG"]]
                URLByAppendingPathComponent:@"Redirected"];
            [NSFileManager.defaultManager createDirectoryAtURL:exportURL
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:NULL];
            NSError *writeError = nil;
            BOOL initialized = [[@"initial fixture" dataUsingEncoding:NSUTF8StringEncoding]
                writeToURL:[exportURL URLByAppendingPathComponent:@"probe.bin"]
                   options:NSDataWritingAtomic
                     error:&writeError];
            if (!initialized) {
                fprintf(stderr, "FAIL synthetic drive initialization (%ld)\n", (long)writeError.code);
                return 1;
            }
            initialized = [[@"Unicode directory fixture" dataUsingEncoding:NSUTF8StringEncoding]
                writeToURL:[exportURL URLByAppendingPathComponent:@"繁體😀.bin"]
                   options:NSDataWritingAtomic
                     error:&writeError];
            if (!initialized)
                return 1;
            for (NSString *path in @[ @"Nested", @"Nested/繁體😀" ]) {
                NSURL *directory = [exportURL URLByAppendingPathComponent:path];
                if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                            withIntermediateDirectories:YES
                                                             attributes:nil
                                                                  error:NULL] ||
                    ![[@"initial fixture" dataUsingEncoding:NSUTF8StringEncoding]
                        writeToURL:[directory URLByAppendingPathComponent:@"probe.bin"]
                        atomically:YES] ||
                    ![[@"Unicode directory fixture" dataUsingEncoding:NSUTF8StringEncoding]
                        writeToURL:[directory URLByAppendingPathComponent:@"繁體😀.bin"]
                        atomically:YES])
                    return 1;
            }
            NSData *bookmark = [exportURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                                   includingResourceValuesForKeys:nil
                                                    relativeToURL:nil
                                                            error:NULL];
            client.redirectedFolders = @[ @{
                @"name" : [mode isEqualToString:@"drive-ro"] ? @"ReadOnly" : @"Shared 繁體😀",
                @"bookmark" : bookmark,
                @"readOnly" : @([mode isEqualToString:@"drive-ro"])
            } ];
        }
        client.onTrust = ^BOOL(NSString *fingerprint, NSString *details) {
          trusted = [fingerprint hasPrefix:@"SHA256:"];
          return ![mode isEqualToString:@"reject"];
        };
        client.onClipboard = ^(NSString *text) {
          if (driveTest && [text isEqualToString:@"Synthetic redirected drive passed"]) {
              drivePassed = YES;
              [weakClient disconnect];
          }
          if (clipboardTest && clipboardCount < samples.count && [text isEqualToString:samples[clipboardCount]]) {
              clipboardCount++;
              if (clipboardCount < samples.count)
                  [weakClient setClipboardText:samples[clipboardCount]];
              else if (frame)
                  [weakClient disconnect];
          }
        };
        client.onCursor = ^(NSData *pixels, NSInteger w, NSInteger h, NSInteger x, NSInteger y) {
        };
        client.onFrame = ^(NSData *pixels, NSInteger w, NSInteger h, NSInteger stride) {
          frame = pixels.length == stride * h && w > 0 && h > 0;
          if (retinaTest)
              frame = frame && w == 1280 && h == 720;
          if (monitorTest) {
              frame = frame && w == 2080 && h == 720;
              if (frame && !finishing) {
                  finishing = YES;
                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                                 dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                                   [weakClient disconnect];
                                 });
              }
              return;
          }
          if (frame && [mode hasPrefix:@"keyboard"]) {
              if (!finishing) {
                  finishing = YES;
                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                                 dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                                   [weakClient disconnect];
                                 });
              }
              return;
          }
          if (frame && !inputOverflowTest && !inputFailureTest && !driveTest && !fileTest &&
              (!clipboardTest || clipboardCount == samples.count))
              [weakClient disconnect];
        };
        client.onStatus = ^(NSString *state, NSString *message) {
          if ([state isEqualToString:@"connected"]) {
              connected = YES;
              if (inputFailureTest) {
                  freerdp *instance = fixtureInstance(weakClient);
                  NSCAssert(instance && freerdp_is_active_state(instance->context), @"Owned active context required");
                  rdpInput *input = instance->context->input;
                  input->KeyboardEvent = failKey;
                  input->UnicodeKeyboardEvent = failUnicode;
                  input->SynchronizeEvent = failSynchronize;
                  input->MouseEvent = failPointer;
                  if ([mode hasSuffix:@"key"])
                      [weakClient sendScanCode:0x1E pressed:NO extended:NO];
                  else if ([mode hasSuffix:@"unicode"])
                      [weakClient sendUnicode:0x61 pressed:NO];
                  else if ([mode hasSuffix:@"sync"])
                      [weakClient synchronizeCapsLock:NO];
                  else
                      [weakClient sendPointerFlags:0x1000 x:10 y:10];
                  // A second event must never be sent after delivery fails.
                  [weakClient sendUnicode:0x62 pressed:NO];
                  return;
              }
              if (inputOverflowTest) {
                  // This callback runs before the worker drains input. Saturate
                  // the bounded queue deterministically without sending keys.
                  for (NSUInteger i = 0; i < 4097; i++)
                      [weakClient sendUnicode:0x61 pressed:NO];
                  return;
              }
              if ([mode hasPrefix:@"keyboard"]) {
                  BOOL paused = [mode isEqualToString:@"keyboard-paused"];
                  freerdp *instance = paused ? fixtureInstance(weakClient) : NULL;
                  if (paused) {
                      NSCAssert(instance && freerdp_is_active_state(instance->context),
                                @"Owned active context required");
                      freerdp_settings_set_bool(instance->context->settings, FreeRDP_SuspendInput, TRUE);
                  }
                  [weakClient sendUnicode:0xE000 pressed:YES];
                  [weakClient sendScanCode:0x2A pressed:YES extended:NO];
                  [weakClient sendScanCode:0x1E pressed:YES extended:NO];
                  [weakClient sendScanCode:0x1E pressed:YES extended:NO];
                  [weakClient sendScanCode:0x1E pressed:NO extended:NO];
                  [weakClient sendScanCode:0x2A pressed:NO extended:NO];
                  for (NSNumber *code in @[ @0x1D, @0x4B ]) {
                      [weakClient sendScanCode:code.integerValue pressed:YES extended:YES];
                      [weakClient sendScanCode:code.integerValue pressed:NO extended:YES];
                  }
                  for (NSNumber *code in @[ @0x4E2D, @0xD83D, @0xDE00 ]) {
                      [weakClient sendUnicode:code.integerValue pressed:YES];
                      [weakClient sendUnicode:code.integerValue pressed:NO];
                  }
                  [weakClient synchronizeCapsLock:YES];
                  [weakClient synchronizeCapsLock:NO];
                  [weakClient sendUnicode:0xE001 pressed:NO];
                  if (paused) {
                      [weakClient setClipboardActive:NO];
                      [weakClient drainEvents:instance->context];
                      NSArray *pending =
                          object_getIvar(weakClient, class_getInstanceVariable(FCRDPClient.class, "_events"));
                      NSCAssert(pending.count == 19,
                                @"Suspended input must remain queued while clipboard control drains");
                      Ivar wakeField = class_getInstanceVariable(FCRDPClient.class, "_inputEvent");
                      HANDLE wake = NULL;
                      memcpy(&wake, (const uint8_t *)(__bridge const void *)weakClient + ivar_getOffset(wakeField),
                             sizeof(wake));
                      NSCAssert(wake && WaitForSingleObject(wake, 0) == WAIT_TIMEOUT,
                                @"Suspended input must not spin the worker wake event");
                      freerdp_settings_set_bool(instance->context->settings, FreeRDP_SuspendInput, FALSE);
                      puts("PASS RDP suspended input retains releases and allows clipboard ownership changes");
                  }
                  return;
              }
              if ([mode isEqualToString:@"pointer-burst"])
                  for (NSUInteger i = 0; i < 10000; i++)
                      [weakClient sendPointerFlags:0x0800 x:i % 1024 y:i % 768];
              [weakClient sendScanCode:0x1E pressed:YES extended:NO];
              [weakClient sendScanCode:0x1E pressed:NO extended:NO];
              [weakClient sendPointerFlags:0x0800 x:50 y:50];
              if (monitorTest) {
                  // An input barrier makes both positions observable; adjacent
                  // motion alone intentionally coalesces to the latest position.
                  [weakClient sendScanCode:0x1E pressed:NO extended:NO];
                  [weakClient sendPointerFlags:0x0800 x:900 y:100];
              }
              if ([mode isEqualToString:@"cancel"])
                  [weakClient disconnect];
          }
          if ([state isEqualToString:@"failed"]) {
              failed = YES;
              overloadReported = [message containsString:@"RDP input could not keep up"];
              printf("  %s\n", message.UTF8String);
          }
          if ([state isEqualToString:@"failed"] || [state isEqualToString:@"disconnected"])
              dispatch_semaphore_signal(done);
        };
        if (clipboardTest)
            [client setClipboardText:samples[0]];
        if (fileTest)
            [client setClipboardFiles:@[ source ]];
        [client connectHost:(tunnelPort ? @"10.111.0.1" : @"127.0.0.1")
                       port:port
                   username:@"fixture"
                     domain:@""
                   password:([mode isEqualToString:@"bad-password"] ? @"wrong" : @"fixture-password")width:1024
                     height:768
                      scale:100
                  clipboard:YES
              audioPlayback:YES];
        BOOL timeout = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC)) != 0;
        [client disconnect];
        [FCRDPClient whenAllDisconnected:^{
          dispatch_semaphore_signal(done);
        }];
        BOOL drained = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
        BOOL pass = !timeout && drained && trusted;
        if (inputOverflowTest)
            pass = pass && connected && failed && overloadReported;
        else if (inputFailureTest)
            pass = pass && connected && failed && retryable && failedInputCalls == 1;
        else if ([mode isEqualToString:@"reject"] || [mode isEqualToString:@"bad-password"])
            pass = pass && failed && !connected;
        else
            pass = pass && connected && !failed && ([mode isEqualToString:@"cancel"] || frame);
        if (monitorTest)
            printf("  Monitor layout reply %s; unconfirmed topology must remain windowed.\n",
                   monitorLayout ? "received" : "unavailable");
        if (clipboardTest)
            pass = pass && clipboardCount == samples.count;
        if (fileTest) {
            NSURL *file = [receivedBatch.files.firstObject URLByAppendingPathComponent:@"Nested/繁體😀.bin"];
            NSDate *modified = [NSFileManager.defaultManager attributesOfItemAtPath:file.path
                                                                              error:NULL][NSFileModificationDate];
            pass = pass && filesPassed && [[NSData dataWithContentsOfURL:file] isEqual:fileBytes] &&
                   fabs(modified.timeIntervalSince1970 - 946684800) < 1;
            // This batch was created by this synthetic client, never a user path.
            NSURL *stage = receivedBatch.files.firstObject.URLByDeletingLastPathComponent;
            if ([stage.lastPathComponent hasPrefix:@"Farcast-RDP-"])
                [NSFileManager.defaultManager removeItemAtURL:stage error:NULL];
        }
        if (driveTest) {
            NSString *expected = [mode isEqualToString:@"drive-ro"] ? @"initial fixture" : @"written fixture";
            BOOL unchanged =
                [[NSData dataWithContentsOfURL:[exportURL URLByAppendingPathComponent:@"Nested/繁體😀/probe.bin"]]
                    isEqual:[expected dataUsingEncoding:NSUTF8StringEncoding]];
            BOOL rootUnchanged = [[NSData dataWithContentsOfURL:[exportURL URLByAppendingPathComponent:@"probe.bin"]]
                isEqual:[@"initial fixture" dataUsingEncoding:NSUTF8StringEncoding]];
            pass = pass && drivePassed && unchanged && rootUnchanged;
        }
        printf("%s RDP %s (trust=%d connected=%d frame=%d)\n", pass ? "PASS" : "FAIL", mode.UTF8String, trusted,
               connected, frame);
        return pass ? 0 : 1;
    }
}
