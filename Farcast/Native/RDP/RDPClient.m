#import "RDPClient.h"
#import "../Transport/WireGuardSocket.h"
#import "RDPClipboard.h"
#import "RDPDrive.h"
#import <Security/Security.h>
// CoreFoundation exports a different REFIID when Clang modules are enabled.
#define REFIID WINPR_REFIID
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmacro-redefined"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import <freerdp/channels/channels.h>
#import <freerdp/client.h>
#import <freerdp/client/channels.h>
#import <freerdp/client/cliprdr.h>
#import <freerdp/client/disp.h>
#import <freerdp/client/rdpgfx.h>
#import <freerdp/codec/color.h>
#import <freerdp/freerdp.h>
#import <freerdp/gdi/gdi.h>
#import <freerdp/gdi/gfx.h>
#import <freerdp/transport_io.h>
#import <winpr/synch.h>
#import <winpr/wlog.h>
#pragma clang diagnostic pop
#import "RDPDisplay.h"
#import <errno.h>
#import <math.h>
#import <netinet/tcp.h>
#import <openssl/err.h>
#import <openssl/pem.h>
#import <openssl/x509.h>
#import <poll.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <time.h>
#import <unistd.h>

typedef struct {
    rdpClientContext common;
    void *owner;
    DispClientContext *display;
    UINT32 maximumMonitors, areaFactorA, areaFactorB;
    BOOL displayCapsReady;
    CliprdrClientContext *clipboard;
    FCRDPClipboard *__unsafe_unretained clipboardBridge;
    double lastFrame;
    pTCPConnect directTCPConnect;
    const char *identityHost;
    int identityPort;
} FCContext;
typedef struct {
    rdpPointer pointer;
    BYTE *pixels;
} FCPointer;
@interface FCRDPClient () {
    NSLock *_lock;
    NSMutableArray<NSDictionary *> *_events;
    NSDictionary *_pendingResize;
    BOOL _eventQueueOverflowed;
    freerdp *_instance;
    atomic_bool _stopped;
    atomic_bool _clipboardActive;
    atomic_bool _running;
    atomic_bool _stalled;
    _Atomic(double) _lastWorkerTick;
    int _interruptSocket;
}
@property(nonatomic, copy) NSString *tunnelFailure;
- (BOOL)runHost:(NSString *)host
             port:(NSInteger)port
         username:(NSString *)username
           domain:(NSString *)domain
         password:(NSString *)password
            width:(NSInteger)width
           height:(NSInteger)height
            scale:(NSInteger)scale
        clipboard:(BOOL)clipboard
    audioPlayback:(BOOL)audioPlayback;
- (void)drainEvents:(FCContext *)context;
- (BOOL)trackSocket:(int)fd;
@end
static dispatch_group_t workers(void) {
    static dispatch_group_t group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      group = dispatch_group_create();
    });
    return group;
}
static FCRDPClient *owner(rdpContext *context) { return (__bridge FCRDPClient *)((FCContext *)context)->owner; }
// Override only TCP dialing; FreeRDP retains the real hostname for TLS/NLA.
// Any server redirection to another endpoint fails closed.
static int monitoredTCPConnect(rdpContext *context, rdpSettings *settings, const char *hostname, int port,
                               DWORD timeout) {
    FCContext *ctx = (FCContext *)context;
    FCRDPClient *client = owner(context);
    if (client.tunnelPort == 0 && client.tunnelToken == nil) {
        int fd = ctx->directTCPConnect(context, settings, hostname, port, timeout);
        if (fd >= 0 && ![client trackSocket:fd]) {
            close(fd);
            return -1;
        }
        return fd;
    }
    if (!hostname || !ctx->identityHost || strcasecmp(hostname, ctx->identityHost) || port != ctx->identityPort ||
        client.tunnelPort <= 0 || client.tunnelPort > 65535 || client.tunnelToken.length != 64)
        return -1;
    int fd = ctx->directTCPConnect(context, settings, "127.0.0.1", (int)client.tunnelPort, timeout);
    if (fd < 0)
        return -1;
    NSString *failure = nil;
    if (FCWireGuardAuthenticateSocket(
            fd, client.tunnelToken,
            ^BOOL {
              return freerdp_shall_disconnect_context(context);
            },
            &failure))
        if ([client trackSocket:fd])
            return fd;
    client.tunnelFailure = failure;
    close(fd);
    return -1;
}

static BOOL beginPaint(rdpContext *context) {
    if (context->gdi) {
        context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
        context->gdi->primary->hdc->hwnd->ninvalid = 0;
    }
    return TRUE;
}
static BOOL endPaint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary_buffer || gdi->width <= 0 || gdi->height <= 0)
        return TRUE;
    // Snapshot bytes while FreeRDP owns the buffer; the renderer never reads
    // native mutable memory.
    FCRDPClient *client = owner(context);
    if (client.onFrame)
        client.onFrame([NSData dataWithBytes:gdi->primary_buffer length:(NSUInteger)gdi->stride * gdi->height],
                       gdi->width, gdi->height, gdi->stride);
    return TRUE;
}
static BOOL desktopResize(rdpContext *context) {
    UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!width || !height || width > FCDisplayMaximumDimension || height > FCDisplayMaximumDimension ||
        (UINT64)width * height > FCDisplayMaximumPixels)
        return FALSE;
    if (!gdi_resize(context->gdi, width, height))
        return FALSE;
    FCRDPClient *client = owner(context);
    if (client.onDesktopSize)
        client.onDesktopSize(width, height);
    return TRUE;
}
static BOOL remoteMonitors(rdpContext *context, UINT32 count, const MONITOR_DEF *monitors) {
    if (count > 16)
        return FALSE;
    NSMutableArray *definitions = [NSMutableArray new];
    for (UINT32 i = 0; i < count; i++) {
        const MONITOR_DEF *m = &monitors[i];
        INT64 width = (INT64)m->right - m->left + 1, height = (INT64)m->bottom - m->top + 1;
        if (width < 200 || height < 200 || width > 8192 || height > 8192)
            return FALSE;
        [definitions addObject:@{
            @"x" : @(m->left),
            @"y" : @(m->top),
            @"width" : @(width),
            @"height" : @(height),
            @"primary" : @((m->flags & 1) != 0)
        }];
    }
    FCRDPClient *client = owner(context);
    if (client.onMonitorLayout)
        client.onMonitorLayout(definitions);
    return TRUE;
}
static UINT displayCapabilities(DispClientContext *display, UINT32 count, UINT32 a, UINT32 b) {
    FCContext *ctx = display->custom;
    if (!ctx)
        return CHANNEL_RC_OK;
    ctx->maximumMonitors = count;
    ctx->areaFactorA = a;
    ctx->areaFactorB = b;
    ctx->displayCapsReady = count && a && b;
    FCRDPClient *client = owner((rdpContext *)ctx);
    if (client.onDisplayAvailability)
        client.onDisplayAvailability(ctx->displayCapsReady);
    return CHANNEL_RC_OK;
}
static BOOL pointerNew(rdpContext *context, rdpPointer *pointer) {
    FCPointer *p = (FCPointer *)pointer;
    if (!pointer->width || !pointer->height || pointer->width > 512 || pointer->height > 512)
        return FALSE;
    p->pixels = calloc(pointer->width * pointer->height, 4);
    return p->pixels && freerdp_image_copy_from_pointer_data(
                            p->pixels, PIXEL_FORMAT_BGRA32, pointer->width * 4, 0, 0, pointer->width, pointer->height,
                            pointer->xorMaskData, pointer->lengthXorMask, pointer->andMaskData, pointer->lengthAndMask,
                            pointer->xorBpp, &context->gdi->palette);
}
static void pointerFree(rdpContext *context, rdpPointer *pointer) { free(((FCPointer *)pointer)->pixels); }
static BOOL pointerSet(rdpContext *context, rdpPointer *pointer) {
    FCRDPClient *client = owner(context);
    FCPointer *p = (FCPointer *)pointer;
    if (p->pixels && client.onCursor)
        client.onCursor([NSData dataWithBytes:p->pixels length:pointer->width * pointer->height * 4], pointer->width,
                        pointer->height, pointer->xPos, pointer->yPos);
    return TRUE;
}
static BOOL pointerDefault(rdpContext *context) {
    FCRDPClient *client = owner(context);
    if (client.onCursor)
        client.onCursor([NSData data], 0, 0, 0, 0);
    return TRUE;
}
static BOOL pointerNull(rdpContext *context) {
    FCRDPClient *client = owner(context);
    if (client.onCursor)
        client.onCursor([NSMutableData dataWithLength:4], 1, 1, 0, 0);
    return TRUE;
}
static void channelConnected(void *context, const ChannelConnectedEventArgs *event) {
    FCContext *ctx = context;
    if (!strcmp(event->name, "rdpgfx"))
        gdi_graphics_pipeline_init(((rdpContext *)context)->gdi, event->pInterface);
    else if (!strcmp(event->name, DISP_DVC_CHANNEL_NAME)) {
        ctx->display = event->pInterface;
        ctx->display->custom = ctx;
        ctx->display->DisplayControlCaps = displayCapabilities;
        ctx->displayCapsReady = NO;
    } else if (!strcmp(event->name, "cliprdr")) {
        ctx->clipboard = event->pInterface;
        [ctx->clipboardBridge attach:ctx->clipboard];
    }
}
static void channelDisconnected(void *context, const ChannelDisconnectedEventArgs *event) {
    FCContext *ctx = context;
    if (!strcmp(event->name, "rdpgfx"))
        gdi_graphics_pipeline_uninit(((rdpContext *)context)->gdi, event->pInterface);
    else if (!strcmp(event->name, DISP_DVC_CHANNEL_NAME)) {
        if (ctx->display) {
            ctx->display->custom = NULL;
            ctx->display->DisplayControlCaps = NULL;
        }
        ctx->display = NULL;
        ctx->displayCapsReady = NO;
        FCRDPClient *client = owner((rdpContext *)ctx);
        [client cancelResize];
        if (client.onDisplayAvailability)
            client.onDisplayAvailability(NO);
    } else if (!strcmp(event->name, "cliprdr")) {
        ctx->clipboard = NULL;
        [ctx->clipboardBridge detach];
    }
}
static BOOL preConnect(freerdp *instance) {
    rdpContext *context = instance->context;
    context->update->RemoteMonitors = remoteMonitors;
    PubSub_SubscribeChannelConnected(context->pubSub, channelConnected);
    PubSub_SubscribeChannelDisconnected(context->pubSub, channelDisconnected);
    return freerdp_client_load_addins(context->channels, context->settings);
}
static BOOL postConnect(freerdp *instance) {
    if (freerdp_settings_get_uint32(instance->context->settings, FreeRDP_DesktopWidth) > FCDisplayMaximumDimension ||
        freerdp_settings_get_uint32(instance->context->settings, FreeRDP_DesktopHeight) > FCDisplayMaximumDimension ||
        (UINT64)freerdp_settings_get_uint32(instance->context->settings, FreeRDP_DesktopWidth) *
                freerdp_settings_get_uint32(instance->context->settings, FreeRDP_DesktopHeight) >
            FCDisplayMaximumPixels)
        return FALSE;
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
        return FALSE;
    instance->context->update->BeginPaint = beginPaint;
    instance->context->update->EndPaint = endPaint;
    instance->context->update->DesktopResize = desktopResize;
    FCRDPClient *client = owner(instance->context);
    if (client.onDesktopSize)
        client.onDesktopSize(instance->context->gdi->width, instance->context->gdi->height);
    rdpPointer pointer = {0};
    pointer.size = sizeof(FCPointer);
    pointer.New = pointerNew;
    pointer.Free = pointerFree;
    pointer.Set = pointerSet;
    pointer.SetNull = pointerNull;
    pointer.SetDefault = pointerDefault;
    graphics_register_pointer(instance->context->graphics, &pointer);
    return TRUE;
}
static void postDisconnect(freerdp *instance) {
    if (instance->context->gdi)
        gdi_free(instance);
}
static NSString *certificateFingerprint(const char *value, DWORD flags) {
    if (!value)
        return nil;
    if (!(flags & VERIFY_CERT_FLAG_FP_IS_PEM))
        return [NSString stringWithUTF8String:value];
    BIO *bio = BIO_new_mem_buf(value, -1);
    if (!bio)
        return nil;
    X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    BIO_free(bio);
    if (!cert)
        return nil;
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int length = 0;
    BOOL ok = X509_digest(cert, EVP_sha256(), digest, &length);
    X509_free(cert);
    if (!ok)
        return nil;
    return [@"SHA256:" stringByAppendingString:[[[NSData dataWithBytes:digest
                                                                length:length] base64EncodedStringWithOptions:0]
                                                   stringByReplacingOccurrencesOfString:@"="
                                                                             withString:@""]];
}
static int verifyX509(freerdp *instance, const BYTE *pem, size_t length, const char *host, UINT16 port, DWORD flags) {
    BIO *bio = BIO_new_mem_buf(pem, (int)length);
    if (!bio)
        return 0;
    NSMutableArray *certificates = [NSMutableArray new];
    X509 *certificate;
    while ((certificate = PEM_read_bio_X509(bio, NULL, NULL, NULL))) {
        unsigned char *der = NULL;
        int count = i2d_X509(certificate, &der);
        if (count > 0 && der) {
            NSData *data = [NSData dataWithBytes:der length:count];
            SecCertificateRef item = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);
            if (item) {
                [certificates addObject:CFBridgingRelease(item)];
            }
        }
        OPENSSL_free(der);
        X509_free(certificate);
    }
    BIO_free(bio);
    ERR_clear_error();
    if (!certificates.count)
        return 0;
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)[NSString stringWithUTF8String:host]);
    SecTrustRef trust = NULL;
    CFErrorRef error = NULL;
    OSStatus status = SecTrustCreateWithCertificates((__bridge CFArrayRef)certificates, policy, &trust);
    CFRelease(policy);
    BOOL valid = NO;
    if (status == errSecSuccess && trust) {
        SecTrustSetNetworkFetchAllowed(trust, false);
        valid = SecTrustEvaluateWithError(trust, &error);
        CFRelease(trust);
    }
    NSString *reason =
        error ? [CFBridgingRelease(error) localizedDescription] : @"The certificate could not be verified.";
    if (valid)
        return 1;
    NSString *pemString = [[NSString alloc] initWithBytes:pem length:length encoding:NSUTF8StringEncoding];
    NSString *hash = certificateFingerprint(pemString.UTF8String, VERIFY_CERT_FLAG_FP_IS_PEM);
    NSString *name =
        CFBridgingRelease(SecCertificateCopySubjectSummary((__bridge SecCertificateRef)certificates.firstObject));
    FCRDPClient *client = owner(instance->context);
    NSString *details = [NSString stringWithFormat:@"RDP TLS certificate\nName: %@\n%@", name ?: @"Unknown", reason];
    return hash && client.onTrust && client.onTrust(hash, details) ? 1 : 0;
}
static BOOL authenticate(freerdp *instance, char **user, char **password, char **domain, rdp_auth_reason reason) {
    return FALSE;
}
static BOOL clientNew(freerdp *instance, rdpContext *context) {
    instance->LoadChannels = freerdp_client_load_channels;
    instance->PreConnect = preConnect;
    instance->PostConnect = postConnect;
    instance->PostDisconnect = postDisconnect;
    instance->VerifyX509Certificate = verifyX509;
    instance->AuthenticateEx = authenticate;
    return TRUE;
}
static void destroyContext(rdpContext *context) {
    freerdp *instance = context->instance;
    freerdp_context_free(instance);
    freerdp_free(instance);
}
@implementation FCRDPClient {
    FCRDPClipboard *_clipboardBridge;
    FCRDPDriveManager *_driveManager;
}
+ (void)whenAllDisconnected:(void (^)(void))completion {
    dispatch_group_notify(workers(), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), completion);
}
- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _events = [NSMutableArray new];
        atomic_init(&_stopped, false);
        atomic_init(&_clipboardActive, true);
        atomic_init(&_running, false);
        atomic_init(&_stalled, false);
        atomic_init(&_lastWorkerTick, 0);
        _interruptSocket = -1;
    }
    return self;
}
- (void)status:(NSString *)state message:(NSString *)message {
    if (self.onStatus)
        self.onStatus(state, message);
}
- (void)connectHost:(NSString *)host
               port:(NSInteger)port
           username:(NSString *)username
             domain:(NSString *)domain
           password:(NSString *)password
              width:(NSInteger)width
             height:(NSInteger)height
              scale:(NSInteger)scale
          clipboard:(BOOL)clipboard
      audioPlayback:(BOOL)audioPlayback {
    dispatch_group_enter(workers());
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
          BOOL retryable = [self runHost:host
                                    port:port
                                username:username
                                  domain:domain
                                password:password
                                   width:width
                                  height:height
                                   scale:scale
                               clipboard:clipboard
                           audioPlayback:audioPlayback];
          if (self.onStopped)
              self.onStopped(retryable);
      }
      dispatch_group_leave(workers());
    });
}
- (BOOL)runHost:(NSString *)host
             port:(NSInteger)port
         username:(NSString *)username
           domain:(NSString *)domain
         password:(NSString *)password
            width:(NSInteger)width
           height:(NSInteger)height
            scale:(NSInteger)scale
        clipboard:(BOOL)clipboard
    audioPlayback:(BOOL)audioPlayback {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      [FCRDPDriveManager registerProvider];
      WLog_SetLogLevel(WLog_GetRoot(), WLOG_ERROR);
    });
    [self status:@"connecting" message:@"Connecting to remote desktop…"];
    // The common client constructor resets the process-wide addin provider on
    // every session. Use the core context API so concurrent sessions keep the
    // selected-folder provider installed throughout device negotiation.
    freerdp *instance = freerdp_new();
    rdpContext *context = NULL;
    if (instance) {
        instance->ContextSize = sizeof(FCContext);
        instance->ContextNew = clientNew;
        if (freerdp_context_new(instance))
            context = instance->context;
        else
            freerdp_free(instance);
    }
    if (!context) {
        [self status:@"failed" message:@"Could not initialize RDP."];
        return NO;
    }
    ((FCContext *)context)->owner = (__bridge void *)self;
    _clipboardBridge = [FCRDPClipboard new];
    [_clipboardBridge setActive:atomic_load(&_clipboardActive)];
    ((FCContext *)context)->clipboardBridge = _clipboardBridge;
    __weak FCRDPClient *weakSelf = self;
    _clipboardBridge.onText = ^(NSString *text) {
      if (weakSelf.onClipboard)
          weakSelf.onClipboard(text);
    };
    if (self.onClipboardBatch)
        _clipboardBridge.onBatch = ^(FCRDPClipboardFileBatch *batch) {
          if (weakSelf.onClipboardBatch)
              weakSelf.onClipboardBatch(batch);
        };
    _clipboardBridge.onFiles = ^(NSArray<NSURL *> *files) {
      if (weakSelf.onClipboardFiles)
          weakSelf.onClipboardFiles(files);
    };
    _clipboardBridge.onRemoteChange = ^{
      if (weakSelf.onClipboardChange)
          weakSelf.onClipboardChange();
    };
    _clipboardBridge.onProgress = ^(NSString *message) {
      if (weakSelf.onClipboardProgress)
          weakSelf.onClipboardProgress(message);
    };
    rdpSettings *s = context->settings;
    {
        FCContext *ctx = (FCContext *)context;
        ctx->identityHost = host.UTF8String;
        ctx->identityPort = (int)port;
        rdpTransportIo callbacks = *freerdp_get_io_callbacks(context);
        ctx->directTCPConnect = callbacks.TCPConnect;
        callbacks.TCPConnect = monitoredTCPConnect;
        if (!freerdp_set_io_callbacks(context, &callbacks)) {
            destroyContext(context);
            [self status:@"failed" message:@"Could not initialize the RDP transport."];
            return NO;
        }
    }
    if (self.tunnelPort != 0 || self.tunnelToken != nil) {
        freerdp_settings_set_bool(s, FreeRDP_SupportMultitransport, FALSE);
        freerdp_settings_set_uint32(s, FreeRDP_MultitransportFlags, 0);
        freerdp_settings_set_bool(s, FreeRDP_GatewayEnabled, FALSE);
    }
    NSString *configRoot = NSProcessInfo.processInfo.environment[@"FARCAST_RDP_CONFIG"];
    if (!configRoot)
        configRoot =
            [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                stringByAppendingPathComponent:@"Farcast/RDP"];
    [[NSFileManager defaultManager] createDirectoryAtPath:configRoot
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700}
                                                    error:NULL];
    freerdp_settings_set_string(s, FreeRDP_ConfigPath, configRoot.UTF8String);
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, host.UTF8String);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)port);
    freerdp_settings_set_string(s, FreeRDP_Username, username.UTF8String);
    freerdp_settings_set_string(s, FreeRDP_Password, password.UTF8String);
    freerdp_settings_set_string(s, FreeRDP_Domain, domain.UTF8String);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)width);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)height);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, (UINT32)scale);
    freerdp_settings_set_uint32(s, FreeRDP_DeviceScaleFactor, scale >= 200 ? 180 : 100);
    if (!FCConfigureMonitorDefinitions(s, self.monitorDefinitions ?: @[])) {
        destroyContext(context);
        [self status:@"failed" message:@"The requested RDP monitor layout is invalid."];
        return NO;
    }
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
    freerdp_settings_set_uint32(s, FreeRDP_KeyboardLayout, 0x00000409);
    freerdp_settings_set_bool(s, FreeRDP_SoftwareGdi, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_ExternalCertificateManagement, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_IgnoreCertificate, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_CertificateCallbackPreferPEM, TRUE);
    _driveManager = [FCRDPDriveManager new];
    if (![_driveManager configure:self.redirectedFolders ?: @[] settings:s]) {
        [_driveManager close];
        _driveManager = nil;
        destroyContext(context);
        [self status:@"failed"
             message:@"A redirected folder is unavailable. Edit the connection and choose the folder again."];
        return NO;
    }
    freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, clipboard);
    freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, audioPlayback);
    freerdp_settings_set_bool(s, FreeRDP_RemoteConsoleAudio, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_AudioCapture, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_SupportDynamicChannels, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, TRUE);
    // The supplied real server completed authentication but never started the
    // negotiated GFX channel. Standard software bitmap updates deliver its desktop.
    // Keep display control available independently of graphics-pipeline negotiation.
    freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RemoteFxCodec, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_NSCodec, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxH264, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_GfxProgressive, FALSE);
    freerdp_settings_set_uint32(s, FreeRDP_TcpConnectTimeout, 20000);
    freerdp_settings_set_uint32(s, FreeRDP_TcpAckTimeout, 20000);
    freerdp_settings_set_bool(s, FreeRDP_TcpKeepAlive, TRUE);
    freerdp_settings_set_uint32(s, FreeRDP_TcpKeepAliveDelay, 15);
    freerdp_settings_set_uint32(s, FreeRDP_TcpKeepAliveInterval, 5);
    freerdp_settings_set_uint32(s, FreeRDP_TcpKeepAliveRetries, 3);
    freerdp_settings_set_uint32(s, FreeRDP_ThreadingFlags, THREADING_FLAGS_DISABLE_THREADS);
    [_lock lock];
    _instance = context->instance;
    BOOL stopped = atomic_load(&_stopped);
    [_lock unlock];
    BOOL connected = !stopped && freerdp_connect(context->instance);
    NSString *failure = nil;
    if (connected) {
        atomic_store(&_lastWorkerTick, NSProcessInfo.processInfo.systemUptime);
        atomic_store(&_running, true);
        [self status:@"connected" message:@"RDP connected"];
        while (!atomic_load(&_stopped) && !freerdp_shall_disconnect_context(context)) {
            @autoreleasepool {
                atomic_store(&_lastWorkerTick, NSProcessInfo.processInfo.systemUptime);
                [self drainEvents:(FCContext *)context];
                if (atomic_load(&_stopped))
                    break;
                [_clipboardBridge tick];
                HANDLE handles[64];
                DWORD count = freerdp_get_event_handles(context, handles, 64);
                if (!count || WaitForMultipleObjects(count, handles, FALSE, 16) == WAIT_FAILED ||
                    !freerdp_check_event_handles(context))
                    break;
            }
        }
    }
    UINT32 error = freerdp_get_last_error(context);
    atomic_store(&_running, false);
    BOOL retryable = !atomic_load(&_stopped) &&
                     (atomic_load(&_stalled) || (connected && error == FREERDP_ERROR_SUCCESS) ||
                      error == FREERDP_ERROR_CONNECT_TRANSPORT_FAILED || error == FREERDP_ERROR_CONNECT_FAILED ||
                      error == FREERDP_ERROR_DNS_ERROR || error == FREERDP_ERROR_DNS_NAME_NOT_FOUND);
    if (!atomic_load(&_stopped) && (!connected || error)) {
        failure = self.tunnelFailure
                      ?: [NSString stringWithFormat:@"RDP connection failed (%s). Check credentials, "
                                                    @"server settings, and network access.",
                                                    freerdp_get_last_error_name(error) ?: "unknown error"];
    }
    [_lock lock];
    _instance = NULL;
    if (_eventQueueOverflowed)
        failure =
            @"RDP input could not keep up. The session was disconnected to avoid losing input. Reconnect to continue.";
    if (_interruptSocket >= 0) {
        shutdown(_interruptSocket, SHUT_RDWR);
        close(_interruptSocket);
        _interruptSocket = -1;
    }
    [_lock unlock];
    // Publish loss before channel/drive teardown, which can take time.
    if (atomic_load(&_stalled))
        [self status:@"stale" message:@"The RDP connection stopped responding. Closing the old connection…"];
    else if (failure)
        [self status:@"failed" message:failure];
    else
        [self status:@"disconnected" message:@"RDP disconnected"];
    freerdp_disconnect(context->instance);
    destroyContext(context);
    [_driveManager close];
    _driveManager = nil;
    [_clipboardBridge detach];
    _clipboardBridge = nil;
    [_lock lock];
    [_events removeAllObjects];
    _pendingResize = nil;
    [_lock unlock];
    return retryable;
}
- (BOOL)trackSocket:(int)fd {
    // FreeRDP's TcpAckTimeout uses TCP_USER_TIMEOUT, which Darwin does not expose.
    int seconds = 20;
    if (setsockopt(fd, IPPROTO_TCP, TCP_RXT_CONNDROPTIME, &seconds, sizeof(seconds)) != 0)
        return NO;
    [_lock lock];
    if (_interruptSocket >= 0)
        close(_interruptSocket);
    _interruptSocket = dup(fd);
    BOOL ready = _interruptSocket >= 0 && !atomic_load(&_stopped);
    if (!ready && _interruptSocket >= 0) {
        close(_interruptSocket);
        _interruptSocket = -1;
    }
    [_lock unlock];
    return ready;
}
- (BOOL)responsive {
    return !atomic_load(&_running) || NSProcessInfo.processInfo.systemUptime - atomic_load(&_lastWorkerTick) < 30;
}
- (void)interruptStalledConnection {
    [_lock lock];
    if (atomic_load(&_running)) {
        atomic_store(&_stalled, true);
        if (_instance)
            freerdp_abort_connect_context(_instance->context);
        if (_interruptSocket >= 0)
            shutdown(_interruptSocket, SHUT_RDWR);
    }
    [_lock unlock];
}
- (void)enqueue:(NSDictionary *)event {
    [_lock lock];
    if (atomic_load(&_stopped)) {
        [_lock unlock];
        return;
    }
    // Only consecutive pure motion may be replaced. Buttons, wheel events and
    // keys are ordering barriers and must never disappear under backpressure.
    NSDictionary *last = _events.lastObject;
    if ([event[@"type"] isEqualToString:@"pointer"] && [event[@"flags"] unsignedIntValue] == PTR_FLAGS_MOVE &&
        [last[@"type"] isEqualToString:@"pointer"] && [last[@"flags"] unsignedIntValue] == PTR_FLAGS_MOVE)
        [_events removeLastObject];
    if ([event[@"type"] isEqualToString:@"resize"]) {
        NSIndexSet *old = [_events indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger index, BOOL *stop) {
          return [item[@"type"] isEqualToString:@"resize"];
        }];
        [_events removeObjectsAtIndexes:old];
    }
    if (_events.count < 4096)
        [_events addObject:event];
    else {
        // Silent loss could leave a key/button pressed or discard clipboard
        // deactivation. Bound memory by terminating the session explicitly.
        _eventQueueOverflowed = YES;
        atomic_store(&_stopped, true);
        if (_instance)
            freerdp_abort_connect_context(_instance->context);
    }
    [_lock unlock];
}
- (void)drainEvents:(FCContext *)ctx {
    rdpContext *context = (rdpContext *)ctx;
    // FreeRDP reports success while silently skipping input during graphics
    // reactivation or suspension. Keep key/button releases queued until active.
    BOOL inputReady =
        freerdp_is_active_state(context) && !freerdp_settings_get_bool(context->settings, FreeRDP_SuspendInput);
    [_lock lock];
    NSArray *events;
    if (inputReady) {
        events = [_events copy];
        [_events removeAllObjects];
    } else {
        // Clipboard ownership/cancellation must still progress while input waits.
        NSIndexSet *ready =
            [_events indexesOfObjectsPassingTest:^BOOL(NSDictionary *event, NSUInteger index, BOOL *stop) {
              NSString *type = event[@"type"];
              return ![type isEqualToString:@"key"] && ![type isEqualToString:@"unicode"] &&
                     ![type isEqualToString:@"pointer"] && ![type isEqualToString:@"synchronize"];
            }];
        events = [_events objectsAtIndexes:ready];
        [_events removeObjectsAtIndexes:ready];
    }
    [_lock unlock];
    for (NSDictionary *event in events) {
        if (atomic_load(&_stopped))
            break;
        NSString *type = event[@"type"];
        if ([type isEqualToString:@"key"])
            freerdp_input_send_keyboard_event_ex(
                context->input, [event[@"pressed"] boolValue], [event[@"repeat"] boolValue],
                [event[@"code"] unsignedIntValue] | ([event[@"extended"] boolValue] ? 0x100 : 0));
        else if ([type isEqualToString:@"unicode"])
            freerdp_input_send_unicode_keyboard_event(context->input,
                                                      [event[@"pressed"] boolValue] ? 0 : KBD_FLAGS_RELEASE,
                                                      [event[@"code"] unsignedShortValue]);
        else if ([type isEqualToString:@"synchronize"])
            freerdp_input_send_synchronize_event(context->input, [event[@"caps"] boolValue] ? KBD_SYNC_CAPS_LOCK : 0);
        else if ([type isEqualToString:@"pointer"])
            freerdp_input_send_mouse_event(context->input, [event[@"flags"] unsignedShortValue],
                                           [event[@"x"] unsignedShortValue], [event[@"y"] unsignedShortValue]);
        else if ([type isEqualToString:@"resize"]) {
            _pendingResize = event;
        } else if ([type isEqualToString:@"cancelResize"]) {
            _pendingResize = nil;
        } else if ([type isEqualToString:@"clipboard"]) {
            [ctx->clipboardBridge setText:event[@"text"]];
        } else if ([type isEqualToString:@"clipboardFiles"]) {
            [ctx->clipboardBridge setFiles:event[@"files"]];
        } else if ([type isEqualToString:@"clipboardActive"]) {
            [ctx->clipboardBridge setActive:[event[@"active"] boolValue]];
        }
    }
    if (atomic_load(&_stopped))
        return;
    if (_pendingResize && ctx->display && ctx->displayCapsReady) {
        NSDictionary *event = _pendingResize;
        _pendingResize = nil;
        DISPLAY_CONTROL_MONITOR_LAYOUT layout = {0};
        layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
        layout.Width = [event[@"width"] unsignedIntValue];
        layout.Height = [event[@"height"] unsignedIntValue];
        layout.DesktopScaleFactor = [event[@"scale"] unsignedIntValue];
        layout.DeviceScaleFactor = layout.DesktopScaleFactor >= 200 ? 180 : 100;
        NSString *result;
        // Unknown physical dimensions are omitted; backing density is not physical DPI.
        if (self.monitorDefinitions.count > 1 || layout.DesktopScaleFactor < 100 || layout.DesktopScaleFactor > 500 ||
            layout.Width < 200 || layout.Width > 8192 || layout.Width % 2 || layout.Height < 200 ||
            layout.Height > 8192 ||
            !FCDisplayAreaAllowed(1, (UINT64)layout.Width * layout.Height, ctx->maximumMonitors, ctx->areaFactorA,
                                  ctx->areaFactorB)) {
            result = @"restricted";
        } else {
            UINT sent = ctx->display->SendMonitorLayout(ctx->display, 1, &layout);
            result = sent == CHANNEL_RC_OK ? @"submitted" : @"failed";
        }
        if (self.onResizeResult)
            self.onResizeResult([event[@"requestID"] integerValue], result);
    }
}
- (void)resizeWidth:(NSInteger)width height:(NSInteger)height scale:(NSInteger)scale {
    [self resizeWidth:width height:height scale:scale requestID:0];
}
- (void)resizeWidth:(NSInteger)width height:(NSInteger)height scale:(NSInteger)scale requestID:(NSInteger)requestID {
    [self enqueue:@{
        @"type" : @"resize",
        @"width" : @(MAX(200, MIN(8192, width / 2 * 2))),
        @"height" : @(MAX(200, MIN(8192, height))),
        @"scale" : @(scale),
        @"requestID" : @(requestID)
    }];
}
- (void)cancelResize {
    [self enqueue:@{@"type" : @"cancelResize"}];
}
- (void)sendScanCode:(NSInteger)code pressed:(BOOL)pressed extended:(BOOL)extended {
    [self enqueue:@{@"type" : @"key", @"code" : @(code), @"pressed" : @(pressed), @"extended" : @(extended)}];
}
- (void)sendUnicode:(NSInteger)code pressed:(BOOL)pressed {
    [self enqueue:@{@"type" : @"unicode", @"code" : @(code), @"pressed" : @(pressed)}];
}
- (void)synchronizeCapsLock:(BOOL)enabled {
    [self enqueue:@{@"type" : @"synchronize", @"caps" : @(enabled)}];
}
- (void)sendPointerFlags:(NSInteger)flags x:(NSInteger)x y:(NSInteger)y {
    [self enqueue:@{@"type" : @"pointer", @"flags" : @(flags), @"x" : @(x), @"y" : @(y)}];
}
- (void)setClipboardText:(NSString *)text {
    if (text.length <= 512 * 1024)
        [self enqueue:@{@"type" : @"clipboard", @"text" : text}];
}
- (void)setClipboardFiles:(NSArray<NSURL *> *)files {
    [self enqueue:@{@"type" : @"clipboardFiles", @"files" : [files copy]}];
}
- (void)setClipboardActive:(BOOL)active {
    atomic_store(&_clipboardActive, active);
    [self enqueue:@{@"type" : @"clipboardActive", @"active" : @(active)}];
}
- (void)sendControlAltDelete {
    [self sendScanCode:0x1D pressed:YES extended:NO];
    [self sendScanCode:0x38 pressed:YES extended:NO];
    [self sendScanCode:0x53 pressed:YES extended:YES];
    [self sendScanCode:0x53 pressed:NO extended:YES];
    [self sendScanCode:0x38 pressed:NO extended:NO];
    [self sendScanCode:0x1D pressed:NO extended:NO];
}
- (void)disconnect {
    atomic_store(&_stopped, true);
    [_lock lock];
    if (_instance)
        freerdp_abort_connect_context(_instance->context);
    if (_interruptSocket >= 0)
        shutdown(_interruptSocket, SHUT_RDWR);
    [_lock unlock];
}
@end
