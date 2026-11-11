// Exercise the production paint callback on a channel-like thread whose outer
// autorelease pool does not drain until the connection ends.
#import "../../../Farcast/Native/RDP/RDPClient.m"
#include <limits.h>

BOOL FCCheckFrameMemory(BOOL regions, void (^consume)(NSData *, int, int)) {
    @autoreleasepool {
        FCRDPClient *client = [FCRDPClient new];
        client.experimentalGraphics = YES;
        FCContext ctx = {0};
        ctx.owner = (__bridge void *)client;
        ctx.graphicsConnected = YES;
        GDI_RGN invalid = {.x = 0, .y = 0, .w = 512, .h = 512};
        GDI_WND window = {.invalid = &invalid};
        GDI_DC dc = {.hwnd = &window};
        gdiBitmap primary = {.hdc = &dc};
        rdpGdi gdi = {.width = 512, .height = 512, .stride = 512 * 4, .primary = &primary};
        gdi.primary_buffer = calloc(512 * 512, 4);
        if (!gdi.primary_buffer)
            return NO;
        rdpContext *context = (rdpContext *)&ctx;
        context->gdi = &gdi;
        __block __weak NSData *lastBytes;
        __block NSUInteger delivered = 0;
        void (^receive)(NSData *, int, int) = ^(NSData *bytes, int width, int height) {
          lastBytes = bytes;
          delivered++;
          consume(bytes, width, height);
        };
        if (regions)
            client.onFrameRegion = ^(NSData *bytes, NSInteger w, NSInteger h, NSInteger x, NSInteger y, NSInteger width,
                                     NSInteger height) {
              receive(bytes, (int)width, (int)height);
            };
        else
            client.onFrame = ^(NSData *bytes, NSInteger w, NSInteger h, NSInteger stride) {
              receive(bytes, (int)w, (int)h);
            };
        BOOL released = YES;
        for (int i = 0; i < 256; i++) {
            memset(gdi.primary_buffer, i, 512 * 512 * 4);
            if (!endPaint(context) || lastBytes != nil) {
                released = NO;
                break;
            }
        }
        __block BOOL boundsValid = YES;
        if (regions) {
            __block NSUInteger patches = 0;
            __block NSInteger patchX = 0, patchY = 0, patchWidth = 0, patchHeight = 0;
            client.onFrameRegion = ^(NSData *bytes, NSInteger w, NSInteger h, NSInteger x, NSInteger y, NSInteger width,
                                     NSInteger height) {
              patches++;
              patchX = x;
              patchY = y;
              patchWidth = width;
              patchHeight = height;
              boundsValid = boundsValid && bytes.length == (NSUInteger)width * height * 4;
            };
            invalid = (GDI_RGN){.x = 510, .y = 509, .w = INT_MAX, .h = INT_MAX};
            endPaint(context);
            boundsValid =
                boundsValid && patches == 1 && patchX == 510 && patchY == 509 && patchWidth == 2 && patchHeight == 3;
            invalid = (GDI_RGN){.x = -2, .y = -3, .w = 8, .h = 10};
            endPaint(context);
            boundsValid =
                boundsValid && patches == 2 && patchX == 0 && patchY == 0 && patchWidth == 6 && patchHeight == 7;
            invalid = (GDI_RGN){.x = INT_MAX, .y = INT_MAX, .w = INT_MAX, .h = INT_MAX};
            endPaint(context);
            boundsValid = boundsValid && patches == 2;
        }
        free(gdi.primary_buffer);
        return released && delivered == 256 && boundsValid;
    }
}
