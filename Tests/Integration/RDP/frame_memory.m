// Exercise the production paint callback on a channel-like thread whose outer
// autorelease pool does not drain until the connection ends.
#import "../../../Farcast/Native/RDP/RDPClient.m"

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
        free(gdi.primary_buffer);
        return released && delivered == 256;
    }
}
