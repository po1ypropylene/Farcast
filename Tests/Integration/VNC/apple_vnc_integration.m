#import "../../../Farcast/Native/VNC/VNCClient.h"
#import <openssl/sha.h>
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4)
            return 2;
        NSString *mode = @(argv[2]), *root = @(argv[3]);
        FCVNCClient *client = [FCVNCClient new];
        client.appleVirtualDisplay = YES;
        BOOL retina = [mode isEqual:@"retina-input"];
        client.retinaDisplay = retina;
        NSInteger factor = retina ? 2 : 1;
        client.desktopWidth = 640;
        client.desktopHeight = 480;
        dispatch_semaphore_t completed = dispatch_semaphore_create(0);
        __block BOOL sawFirst = NO, sawResized = NO, sawConnected = NO, sawKeyboard = NO, sawInteractive = NO,
                     failed = NO;
        __weak FCVNCClient *weakClient = client;
        __block NSString *failure;
        client.onTrust = ^BOOL(NSString *pin, NSString *details) {
          NSData *key = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"public.der"]];
          unsigned char hash[32];
          SHA256(key.bytes, key.length, hash);
          NSString *expected = [@"SHA256:"
              stringByAppendingString:[[[NSData dataWithBytes:hash length:32] base64EncodedStringWithOptions:0]
                                          stringByReplacingOccurrencesOfString:@"="
                                                                    withString:@""]];
          NSCAssert([pin isEqual:expected], @"Synthetic server identity mismatch");
          return ![mode isEqual:@"trust-refusal"];
        };
        client.onStatus = ^(NSString *state, NSString *message) {
          if ([state isEqual:@"connected"]) {
              NSCAssert(sawFirst, @"Apple connection reported before desktop pixels");
              sawConnected = YES;
          }
          if ([state isEqual:@"failed"]) {
              failed = YES;
              failure = message;
              dispatch_semaphore_signal(completed);
          }
        };
        client.onKeyboardInput = ^{
          NSCAssert(!sawKeyboard, @"Keyboard activity notification must be one-shot");
          sawKeyboard = YES;
        };
        client.onFrame = ^(NSData *pixels, NSInteger w, NSInteger h, NSInteger stride) {
          const unsigned char *p = pixels.bytes;
          NSCAssert(stride == w * 4 && (p[0] == 17 || p[0] == 29) && p[pixels.length - 2] == 83,
                    @"Encrypted framebuffer pixels");
          if (p[0] == 29)
              sawInteractive = YES;
          if (w == 640 * factor && h == 480 * factor && !sawFirst) {
              sawFirst = YES;
              [weakClient sendKeySym:0xff09 pressed:YES];
              [weakClient sendKeySym:0xff09 pressed:NO];
              [weakClient sendPointerMask:1 x:w - 1 y:h - 1];
              [weakClient sendPointerMask:0 x:w - 1 y:h - 1];
              [weakClient sendControlAltDelete];
              NSCAssert([weakClient typeText:@"A😀"], @"Synthetic Apple typing request");
              if ([mode isEqual:@"input-latency"])
                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                   [weakClient sendKeySym:0xff1b pressed:YES];
                                   [weakClient sendKeySym:0xff1b pressed:NO];
                                 });
              [weakClient resizeAppleWidth:800 height:600];
          }
          if (w == 800 * factor && h == 600 * factor) {
              sawResized = YES;
              dispatch_semaphore_signal(completed);
          }
        };
        [client connectHost:@"127.0.0.1" port:atoi(argv[1]) username:@"fixture" password:@"fixture-password"];
        NSCAssert(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) == 0,
                  @"Apple VNC fixture timed out");
        if ([mode isEqual:@"success"] || [mode isEqual:@"desktop-size"] || [mode isEqual:@"desktop-login"] ||
            [mode isEqual:@"rekey-input"] || [mode isEqual:@"input-latency"] || retina)
            NSCAssert(sawFirst && sawResized && sawConnected && sawKeyboard && sawInteractive && !failed,
                      @"Apple display/resize failed: %@", failure);
        else
            NSCAssert(failed && !sawFirst, @"Invalid peer/identity must fail before pixels");
        [client disconnect];
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        [FCVNCClient whenAllDisconnected:^{
          dispatch_semaphore_signal(stopped);
        }];
        NSCAssert(dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
                  @"Apple worker did not retire");
        printf("PASS Apple VNC %s\n", mode.UTF8String);
    }
}
