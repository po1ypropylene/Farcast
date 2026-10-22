// Compile the owned adapter into this test translation unit to exercise its
// private channel callbacks without adding a production testing API.
#import "../../../Farcast/Native/RDP/RDPClient.m"

int main(void) {
    @autoreleasepool {
        FCRDPClient *client = [FCRDPClient new];
        FCContext ctx = {0};
        rdpContext *context = (rdpContext *)&ctx;
        ctx.owner = (__bridge void *)client;
        context->settings = freerdp_settings_new(0);
        if (!context->settings)
            return 1;
        freerdp_settings_set_uint32(context->settings, FreeRDP_DesktopWidth, 640);
        freerdp_settings_set_uint32(context->settings, FreeRDP_DesktopHeight, 480);
        freerdp_settings_set_uint32(context->settings, FreeRDP_ThreadingFlags, THREADING_FLAGS_DISABLE_THREADS);
        rdpGdi gdi = {0};
        gdi.context = context;
        context->gdi = &gdi;
        RdpgfxClientContext gfx = {0};
        ChannelConnectedEventArgs connected = {0};
        connected.name = RDPGFX_DVC_CHANNEL_NAME;
        connected.pInterface = &gfx;
        channelConnected(context, &connected);
        if (!ctx.graphicsConnected || gfx.custom != &gdi || !gfx.codecs || !ctx.surfaceCommand || !ctx.gfxEndFrame ||
            gfx.SurfaceCommand != measuredSurfaceCommand || gfx.EndFrame != measuredGfxEndFrame)
            return 2;
        ChannelDisconnectedEventArgs disconnected = {0};
        disconnected.name = RDPGFX_DVC_CHANNEL_NAME;
        disconnected.pInterface = &gfx;
        channelDisconnected(context, &disconnected);
        if (ctx.graphicsConnected || gfx.custom || gfx.codecs || ctx.surfaceCommand || ctx.gfxEndFrame || gdi.gfx)
            return 3;
        freerdp_settings_free(context->settings);
        puts("PASS full protocol GFX channel name initializes decoder callbacks and retires them on close");
    }
    return 0;
}
