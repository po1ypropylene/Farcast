#import "VNCClient.h"
#import "../Transport/WireGuardSocket.h"
#import "VNCAppleSession.h"
#import <Security/Security.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <netdb.h>
#import <netinet/tcp.h>
#import <openssl/des.h>
#import <openssl/sha.h>
#import <openssl/ssl.h>
#import <stdatomic.h>
#import <unistd.h>
#import <zlib.h>

static dispatch_group_t FCVNCWorkers(void) {
    static dispatch_group_t group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      group = dispatch_group_create();
    });
    return group;
}
static uint16_t Read16(const unsigned char *p) { return ((uint16_t)p[0] << 8) | p[1]; }
static uint32_t Read32(const unsigned char *p) { return ((uint32_t)Read16(p) << 16) | Read16(p + 2); }
static void Put16(unsigned char *p, uint16_t n) {
    p[0] = n >> 8;
    p[1] = n;
}
static void Put32(unsigned char *p, uint32_t n) {
    Put16(p, n >> 16);
    Put16(p + 2, n);
}
static uint32_t KeySym(uint32_t scalar) {
    if (scalar == 10 || scalar == 13)
        return 0xff0d;
    if (scalar == 9)
        return 0xff09;
    return scalar <= 255 ? scalar : 0x01000000 | scalar;
}

@implementation FCVNCClient {
    atomic_bool _cancelled, _ready;
    BOOL _started, _reportedTyping, _reportedFrame, _reportedKeyboard;
    int _fd;
    SSL_CTX *_context;
    SSL *_tls;
    NSMutableArray<NSData *> *_input;
    NSUInteger _inputBytes;
    NSArray<NSNumber *> *_typing;
    NSUInteger _typingIndex;
    double _nextKey;
    NSMutableData *_pixels;
    NSUInteger _width, _height;
    z_stream _inflate;
    BOOL _inflating;
    NSString *_failure;
    FCVNCAppleSession *_apple;
    NSData *_pendingAppleResize;
}
- (instancetype)init {
    if ((self = [super init])) {
        _fd = -1;
        _input = [NSMutableArray array];
    }
    return self;
}
- (BOOL)cancelled {
    @synchronized(self) {
        return _cancelled;
    }
}
- (void)status:(NSString *)state message:(NSString *)message {
    if (self.onStatus)
        self.onStatus(state, message);
}
- (void)disconnect {
    @synchronized(self) {
        _cancelled = YES;
        _ready = NO;
        [_input removeAllObjects];
        _inputBytes = 0;
        _typing = nil;
        if (_fd >= 0)
            shutdown(_fd, SHUT_RDWR);
    }
}
+ (void)whenAllDisconnected:(void (^)(void))completion {
    dispatch_group_notify(FCVNCWorkers(), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), completion);
}
- (BOOL)waitSocket:(short)events deadline:(double)deadline {
    while (![self cancelled] && FCWireGuardSocketTime() < deadline) {
        // Receive fragments can pause while the user is interacting. Drain on
        // the same worker; writable waits never recurse into the input pump.
        if (events == POLLIN && _ready && ![self flushInput])
            return NO;
        struct pollfd p = {_fd, events, 0};
        int r = poll(&p, 1, 10);
        if (r < 0 && errno == EINTR)
            continue;
        if (r < 0 || (p.revents & POLLNVAL))
            return NO;
        if (r && (p.revents & (events | POLLHUP | POLLERR)))
            return YES;
    }
    return NO;
}
- (BOOL)writeTransport:(const void *)bytes count:(NSUInteger)count {
    double deadline = FCWireGuardSocketTime() + 30;
    NSUInteger done = 0;
    while (done < count && ![self cancelled]) {
        int n;
        if (_tls) {
            n = SSL_write(_tls, (const char *)bytes + done, (int)MIN(count - done, 65536));
            if (n <= 0) {
                int e = SSL_get_error(_tls, n);
                if ((e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) &&
                    [self waitSocket:e == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT deadline:deadline])
                    continue;
                return NO;
            }
        } else {
            if (![self waitSocket:POLLOUT deadline:deadline])
                return NO;
            n = (int)send(_fd, (const char *)bytes + done, count - done, MSG_DONTWAIT);
            if (n < 0 && (errno == EAGAIN || errno == EINTR))
                continue;
            if (n <= 0)
                return NO;
        }
        done += n;
    }
    return done == count;
}
- (BOOL)readTransport:(void *)bytes count:(NSUInteger)count {
    double deadline = FCWireGuardSocketTime() + 30;
    NSUInteger done = 0;
    while (done < count && ![self cancelled]) {
        if (_ready && ![self flushInput])
            return NO;
        int n;
        if (_tls) {
            n = SSL_read(_tls, (char *)bytes + done, (int)MIN(count - done, 65536));
            if (n <= 0) {
                int e = SSL_get_error(_tls, n);
                if ((e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) &&
                    [self waitSocket:e == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT deadline:deadline])
                    continue;
                return NO;
            }
        } else {
            if (![self waitSocket:POLLIN deadline:deadline])
                return NO;
            n = (int)recv(_fd, (char *)bytes + done, count - done, MSG_DONTWAIT);
            if (n < 0 && (errno == EAGAIN || errno == EINTR))
                continue;
            if (n <= 0)
                return NO;
        }
        done += n;
        deadline = FCWireGuardSocketTime() + 30;
    }
    return done == count;
}
- (BOOL)write:(const void *)bytes count:(NSUInteger)count {
    BOOL ok = _apple ? [_apple write:bytes count:count] : [self writeTransport:bytes count:count];
    if (!ok && _apple)
        _failure = _apple.failure;
    return ok;
}
- (BOOL)read:(void *)bytes count:(NSUInteger)count {
    BOOL ok = _apple ? [_apple read:bytes count:count] : [self readTransport:bytes count:count];
    if (!ok && _apple)
        _failure = _apple.failure;
    return ok;
}
- (void)resizeAppleWidth:(NSInteger)width height:(NSInteger)height {
    NSData *request =
        width > 0 && height > 0 ? [FCVNCAppleSession displayWidth:width height:height retina:self.retinaDisplay] : nil;
    @synchronized(self) {
        if (!_cancelled && _ready && self.appleVirtualDisplay)
            _pendingAppleResize = request;
    }
}
- (BOOL)discard:(NSUInteger)count {
    unsigned char buffer[4096];
    while (count) {
        NSUInteger n = MIN(count, sizeof(buffer));
        if (![self read:buffer count:n])
            return NO;
        count -= n;
    }
    return YES;
}
- (BOOL)dial:(NSString *)host port:(NSInteger)port {
    if (port < 1 || port > 65535 || self.tunnelPort < 0 || self.tunnelPort > 65535 ||
        (self.tunnelPort && !self.tunnelToken) || (!self.tunnelPort && self.tunnelToken))
        return NO;
    struct addrinfo hints = {0}, *list = NULL;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    NSString *service = [NSString stringWithFormat:@"%ld", (long)(self.tunnelPort ?: port)];
    int lookup = getaddrinfo(self.tunnelPort ? "127.0.0.1" : host.UTF8String, service.UTF8String, &hints, &list);
    if (lookup) {
        _failure = [NSString stringWithFormat:@"VNC address lookup failed (%d): %s.", lookup, gai_strerror(lookup)];
        return NO;
    }
    double deadline = FCWireGuardSocketTime() + 20;
    BOOL connected = NO;
    int connectionError = 0;
    for (struct addrinfo *a = list; a && ![self cancelled]; a = a->ai_next) {
        int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) {
            connectionError = errno;
            continue;
        }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        fcntl(fd, F_SETFL, O_NONBLOCK);
        @synchronized(self) {
            _fd = fd;
            if (_cancelled)
                shutdown(fd, SHUT_RDWR);
        }
        int result = connect(fd, a->ai_addr, a->ai_addrlen);
        connectionError = result ? errno : 0;
        if (result == 0 || (errno == EINPROGRESS && [self waitSocket:POLLOUT deadline:deadline])) {
            int error = 0;
            socklen_t size = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size))
                connectionError = errno;
            else {
                connected = error == 0;
                connectionError = error;
            }
        }
        if (connected)
            break;
        @synchronized(self) {
            _fd = -1;
            close(fd);
        }
    }
    freeaddrinfo(list);
    if (!connected) {
        if (connectionError == EINPROGRESS || FCWireGuardSocketTime() >= deadline)
            connectionError = ETIMEDOUT;
        _failure = [NSString
            stringWithFormat:@"VNC TCP connection failed (%d): %s.%@", connectionError, strerror(connectionError),
                             connectionError == EHOSTUNREACH || connectionError == EACCES || connectionError == EPERM
                                 ? @" Check this Mac’s Local Network permission and network access."
                                 : @""];
        return NO;
    }
    if (self.tunnelPort) {
        NSString *failure = nil;
        BOOL ok = FCWireGuardAuthenticateSocket(
            _fd, self.tunnelToken,
            ^{
              return [self cancelled];
            },
            &failure);
        if (!ok)
            _failure = failure;
        return ok;
    }
    return ![self cancelled];
}
- (BOOL)vncAuth:(NSString *)password {
    unsigned char challenge[16], response[16];
    if (![self read:challenge count:16])
        return NO;
    NSData *data = [password dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:NO];
    if (!data) {
        _failure = @"Classic VNC passwords must use Latin-1 characters.";
        return NO;
    }
    DES_cblock key = {0};
    const unsigned char *p = data.bytes;
    for (NSUInteger i = 0; i < MIN(data.length, 8); i++) {
        unsigned char b = p[i], reversed = 0;
        for (int j = 0; j < 8; j++) {
            reversed = (reversed << 1) | (b & 1);
            b >>= 1;
        }
        key[i] = reversed;
    }
    DES_key_schedule schedule;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    DES_set_key_unchecked(&key, &schedule);
    DES_ecb_encrypt((const_DES_cblock *)challenge, (DES_cblock *)response, &schedule, DES_ENCRYPT);
    DES_ecb_encrypt((const_DES_cblock *)(challenge + 8), (DES_cblock *)(response + 8), &schedule, DES_ENCRYPT);
#pragma clang diagnostic pop
    OPENSSL_cleanse(&schedule, sizeof(schedule));
    OPENSSL_cleanse(key, sizeof(key));
    return [self write:response count:16];
}
- (BOOL)tlsHost:(NSString *)host {
    _context = SSL_CTX_new(TLS_client_method());
    if (!_context)
        return NO;
    SSL_CTX_set_min_proto_version(_context, TLS1_2_VERSION);
    // Trust is decided by macOS and the explicit endpoint-scoped fingerprint prompt below.
    _tls = SSL_new(_context);
    if (!_tls)
        return NO;
    SSL_set_fd(_tls, _fd);
    SSL_set_tlsext_host_name(_tls, host.UTF8String);
    double deadline = FCWireGuardSocketTime() + 30;
    while (![self cancelled]) {
        int result = SSL_connect(_tls);
        if (result == 1)
            break;
        int e = SSL_get_error(_tls, result);
        if ((e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) ||
            ![self waitSocket:e == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT deadline:deadline])
            return NO;
    }
    X509 *certificate = SSL_get1_peer_certificate(_tls);
    if (!certificate)
        return NO;
    unsigned char *der = NULL;
    int length = i2d_X509(certificate, &der);
    X509_free(certificate);
    if (length <= 0)
        return NO;
    NSData *data = [NSData dataWithBytes:der length:length];
    OPENSSL_free(der);
    unsigned char digest[SHA256_DIGEST_LENGTH];
    SHA256(data.bytes, data.length, digest);
    NSString *base = [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
    NSString *pin = [@"SHA256:" stringByAppendingString:[base stringByReplacingOccurrencesOfString:@"="
                                                                                        withString:@""]];
    SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)host);
    SecTrustRef trust = NULL;
    BOOL valid = cert && SecTrustCreateWithCertificates(cert, policy, &trust) == errSecSuccess &&
                 SecTrustEvaluateWithError(trust, NULL);
    if (trust)
        CFRelease(trust);
    if (cert)
        CFRelease(cert);
    CFRelease(policy);
    NSString *details = valid ? @"VNC TLS certificate validated by macOS. Verify this server’s SHA256 fingerprint."
                              : @"VNC TLS certificate is not trusted by macOS. Verify its SHA256 fingerprint "
                                @"independently before connecting.";
    _failure = @"VNC server identity was not approved.";
    return self.onTrust && self.onTrust(pin, details) && ![self cancelled];
}
- (BOOL)authenticateHost:(NSString *)host username:(NSString *)username password:(NSString *)password {
    if (self.appleVirtualDisplay) {
        _apple = [FCVNCAppleSession new];
        __weak FCVNCClient *weakSelf = self;
        _apple.readTransport = ^BOOL(void *bytes, NSUInteger count) {
          return [weakSelf readTransport:bytes count:count];
        };
        _apple.writeTransport = ^BOOL(const void *bytes, NSUInteger count) {
          return [weakSelf writeTransport:bytes count:count];
        };
        _apple.isCancelled = ^BOOL {
          FCVNCClient *owner = weakSelf;
          return !owner || [owner cancelled];
        };
        _apple.approveIdentity = ^BOOL(NSString *pin, NSString *details) {
          FCVNCClient *owner = weakSelf;
          return owner && owner.onTrust && owner.onTrust(pin, details);
        };
        BOOL ok = [_apple authenticateUsername:username password:password];
        if (!ok) {
            _failure = _apple.failure;
            if (_apple.authenticationRejected && self.onAuthenticationRejected)
                self.onAuthenticationRejected();
        }
        return ok;
    }
    _failure = @"VNC server did not send a valid RFB protocol banner.";
    unsigned char banner[12];
    if (![self read:banner count:12] || memcmp(banner, "RFB 003.", 8) || banner[11] != '\n')
        return NO;
    int version;
    if (!memcmp(banner + 8, "008", 3) || !memcmp(banner + 8, "889", 3))
        version = 8;
    else if (!memcmp(banner + 8, "007", 3))
        version = 7;
    else if (!memcmp(banner + 8, "003", 3))
        version = 3;
    else {
        _failure = @"Unsupported VNC protocol version.";
        return NO;
    }
    if (![self write:version == 8 ? "RFB 003.008\n" : version == 7 ? "RFB 003.007\n" : "RFB 003.003\n" count:12])
        return NO;
    uint32_t security = 0;
    if (version == 3) {
        unsigned char value[4];
        if (![self read:value count:4])
            return NO;
        security = Read32(value);
    } else {
        unsigned char count, types[255];
        if (![self read:&count count:1] || !count || ![self read:types count:count])
            return NO;
        // Prefer authenticated TLS; never downgrade if VeNCrypt is offered but unsupported.
        for (int i = 0; i < count; i++)
            if (types[i] == 19)
                security = 19;
        if (!security)
            for (int i = 0; i < count; i++)
                if (types[i] == 2)
                    security = 2;
        if (!security)
            for (int i = 0; i < count; i++)
                if (types[i] == 1)
                    security = 1;
        if (!security) {
            _failure =
                @"Unsupported VNC authentication. Enable VNC password or VeNCrypt X509 authentication on the server.";
            return NO;
        }
        unsigned char choice = security;
        if (![self write:&choice count:1])
            return NO;
    }
    if (security == 19) {
        unsigned char versionBytes[2], answer[2] = {0, 2}, status, count;
        _failure = @"VNC requires VeNCrypt 0.2 with X509None, X509Vnc or X509Plain. Anonymous TLS is unsupported.";
        if (![self read:versionBytes count:2] || versionBytes[0] != 0 || versionBytes[1] != 2 ||
            ![self write:answer count:2] || ![self read:&status count:1] || status != 0 ||
            ![self read:&count count:1] || !count)
            return NO;
        uint32_t subtype = 0;
        for (int i = 0; i < count; i++) {
            unsigned char value[4];
            if (![self read:value count:4])
                return NO;
            uint32_t type = Read32(value);
            if (type == 261 || (type == 262 && subtype != 261) || (type == 260 && !subtype))
                subtype = type;
        }
        if (!subtype)
            return NO;
        unsigned char value[4];
        Put32(value, subtype);
        if (![self write:value count:4] || ![self read:&status count:1] || status != 1 || ![self tlsHost:host])
            return NO;
        if (subtype == 261 && ![self vncAuth:password])
            return NO;
        if (subtype == 262) {
            NSData *user = [username dataUsingEncoding:NSUTF8StringEncoding],
                   *pass = [password dataUsingEncoding:NSUTF8StringEncoding];
            if (!user.length || user.length > 4096 || pass.length > 4096) {
                _failure = @"Enter a username for VNC X509Plain authentication.";
                return NO;
            }
            unsigned char lengths[8];
            Put32(lengths, (uint32_t)user.length);
            Put32(lengths + 4, (uint32_t)pass.length);
            if (![self write:lengths count:8] || ![self write:user.bytes count:user.length] ||
                ![self write:pass.bytes count:pass.length])
                return NO;
        }
    } else if (security == 2) {
        if (![self vncAuth:password])
            return NO;
    } else if (security != 1) {
        _failure = @"Unsupported VNC authentication.";
        return NO;
    }
    if (security != 1 || version == 8) {
        unsigned char result[4];
        if (![self read:result count:4])
            return NO;
        if (Read32(result)) {
            _failure = @"VNC authentication was rejected. Retry sign-in with the server’s VNC password.";
            if (self.onAuthenticationRejected)
                self.onAuthenticationRejected();
            return NO;
        }
    }
    _failure = @"VNC connection ended or sent invalid protocol data.";
    return YES;
}
- (BOOL)sizeWidth:(NSUInteger)width height:(NSUInteger)height {
    if (!width || !height || width > 16384 || height > 16384 || width * height > 64 * 1024 * 1024)
        return NO;
    _width = width;
    _height = height;
    _pixels = [NSMutableData dataWithLength:width * height * 4];
    if (self.onDesktopSize)
        self.onDesktopSize(width, height);
    return YES;
}
- (BOOL)requestFrame:(BOOL)incremental {
    unsigned char request[10] = {3, incremental ? 1 : 0};
    Put16(request + 6, (uint16_t)_width);
    Put16(request + 8, (uint16_t)_height);
    return [self write:request count:10];
}
- (BOOL)initializeDesktopUsername:(NSString *)username password:(NSString *)password {
    unsigned char shared = _apple ? 0xc1 : 1, init[24];
    if (![self write:&shared count:1] || ![self read:init count:24])
        return NO;
    uint32_t nameLength = Read32(init + 20);
    if (nameLength > 1048576)
        return NO;
    NSMutableData *serverInfo = [NSMutableData dataWithLength:nameLength];
    if (![self read:serverInfo.mutableBytes count:nameLength] || ![self sizeWidth:Read16(init) height:Read16(init + 2)])
        return NO;
    if (_apple && ![_apple selectDesktopWithServerInfo:serverInfo username:username password:password]) {
        _failure = _apple.failure;
        return NO;
    }
    if (_apple)
        [self status:@"authenticating"
             message:_apple.desktopLoginRequested ? @"The Mac accepted encrypted desktop login credentials."
                                                  : @"The Mac did not request desktop login selection."];
    // Little-endian BGRX8888; server converts from its native format.
    unsigned char format[20] = {0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0};
    if (_apple && ![_apple bootstrapWidth:self.desktopWidth height:self.desktopHeight retina:self.retinaDisplay]) {
        _failure = @"Apple virtual-display encrypted bootstrap failed.";
        return NO;
    }
    unsigned char encodings[48] = {2, 0, 0, _apple ? 11 : 5};
    Put32(encodings + 4, 6);
    Put32(encodings + 8, 5);
    Put32(encodings + 12, 1);
    Put32(encodings + 16, 0);
    Put32(encodings + 20, (uint32_t)-223);
    Put32(encodings + 24, 0x44f);
    Put32(encodings + 28, 0x450);
    Put32(encodings + 32, 0x451);
    Put32(encodings + 36, 0x455);
    Put32(encodings + 40, 0x456);
    Put32(encodings + 44, 0x453);
    // Apple requires SetEncodings immediately after display configuration.
    return [self write:encodings count:_apple ? 48 : 24] && [self write:format count:20] &&
           (_apple ? [self armAppleUpdates] : [self requestFrame:NO]);
}
- (void)fillX:(NSUInteger)x
            y:(NSUInteger)y
        width:(NSUInteger)w
       height:(NSUInteger)h
        color:(const unsigned char *)color {
    unsigned char *pixels = _pixels.mutableBytes;
    for (NSUInteger row = y; row < y + h; row++)
        for (NSUInteger col = x; col < x + w; col++)
            memcpy(pixels + (row * _width + col) * 4, color, 4);
}
- (BOOL)rawX:(NSUInteger)x y:(NSUInteger)y width:(NSUInteger)w height:(NSUInteger)h {
    for (NSUInteger row = y; row < y + h; row++)
        if (![self read:(unsigned char *)_pixels.mutableBytes + (row * _width + x) * 4 count:w * 4])
            return NO;
    return YES;
}
- (BOOL)hextileX:(NSUInteger)x y:(NSUInteger)y width:(NSUInteger)w height:(NSUInteger)h {
    unsigned char background[4] = {0}, foreground[4] = {0};
    BOOL haveBackground = NO, haveForeground = NO;
    for (NSUInteger ty = y; ty < y + h; ty += 16)
        for (NSUInteger tx = x; tx < x + w; tx += 16) {
            NSUInteger tw = MIN(16, x + w - tx), th = MIN(16, y + h - ty);
            unsigned char flags;
            if (![self read:&flags count:1] || flags & ~31)
                return NO;
            if (flags & 1) {
                if (![self rawX:tx y:ty width:tw height:th])
                    return NO;
                haveBackground = NO;
                haveForeground = NO;
                continue;
            }
            if (flags & 2) {
                if (![self read:background count:4])
                    return NO;
                haveBackground = YES;
            }
            if (!haveBackground)
                return NO;
            [self fillX:tx y:ty width:tw height:th color:background];
            if ((flags & 4) && (flags & 16))
                return NO;
            if (flags & 16)
                haveForeground = NO;
            if (flags & 4) {
                if (![self read:foreground count:4])
                    return NO;
                haveForeground = YES;
            }
            if (flags & 8) {
                unsigned char count;
                if (![self read:&count count:1])
                    return NO;
                for (int i = 0; i < count; i++) {
                    unsigned char color[4], rect[2];
                    if (flags & 16) {
                        if (![self read:color count:4])
                            return NO;
                    } else {
                        if (!haveForeground)
                            return NO;
                        memcpy(color, foreground, 4);
                    }
                    if (![self read:rect count:2])
                        return NO;
                    NSUInteger sx = rect[0] >> 4, sy = rect[0] & 15, sw = (rect[1] >> 4) + 1, sh = (rect[1] & 15) + 1;
                    if (sx + sw > tw || sy + sh > th)
                        return NO;
                    [self fillX:tx + sx y:ty + sy width:sw height:sh color:color];
                }
            }
        }
    return YES;
}
- (BOOL)zlibX:(NSUInteger)x y:(NSUInteger)y width:(NSUInteger)w height:(NSUInteger)h {
    unsigned char lengthBytes[4];
    if (![self read:lengthBytes count:4])
        return NO;
    uint32_t length = Read32(lengthBytes);
    if (!length || length > 64 * 1024 * 1024)
        return NO;
    NSMutableData *compressed = [NSMutableData dataWithLength:length],
                  *decoded = [NSMutableData dataWithLength:w * h * 4 + 1];
    if (![self read:compressed.mutableBytes count:length])
        return NO;
    if (!_inflating) {
        if (inflateInit(&_inflate) != Z_OK)
            return NO;
        _inflating = YES;
    }
    _inflate.next_in = compressed.mutableBytes;
    _inflate.avail_in = length;
    _inflate.next_out = decoded.mutableBytes;
    _inflate.avail_out = (uInt)decoded.length;
    int result = inflate(&_inflate, Z_SYNC_FLUSH);
    if ((result != Z_OK && result != Z_STREAM_END) || _inflate.avail_in ||
        decoded.length - _inflate.avail_out != w * h * 4)
        return NO;
    for (NSUInteger row = 0; row < h; row++)
        memcpy((unsigned char *)_pixels.mutableBytes + ((y + row) * _width + x) * 4,
               (unsigned char *)decoded.bytes + row * w * 4, w * 4);
    if (result == Z_STREAM_END) {
        inflateEnd(&_inflate);
        memset(&_inflate, 0, sizeof(_inflate));
        _inflating = NO;
    }
    return YES;
}
- (BOOL)armAppleUpdates {
    unsigned char packet[16] = {9, 0, 0, 1, 255, 255, 255, 255};
    Put16(packet + 12, _width);
    Put16(packet + 14, _height);
    // A replacement display agent must receive control mode as well as the
    // renewed framebuffer subscription. Streaming alone does not enable input.
    const unsigned char control[] = {0x0a, 0, 0, 1};
    return [self write:control count:sizeof(control)] && [self write:packet count:sizeof(packet)] &&
           [self requestFrame:NO];
}
- (BOOL)appleMetadata:(int32_t)encoding x:(NSUInteger)x y:(NSUInteger)y width:(NSUInteger)w height:(NSUInteger)h {
    if (encoding == 0x44f) {
        unsigned char payload[36];
        return [self read:payload count:36] && [_apple rekey:[NSData dataWithBytes:payload length:36]];
    }
    if (encoding == 0x453)
        return [self discard:22];
    if (encoding == 0x450) {
        unsigned char header[8];
        if (![self read:header count:8])
            return NO;
        uint32_t length = Read32(header + 4);
        if (length > 1024 * 1024 || w > 512 || h > 512)
            return NO;
        // Cursor STORE/SELECT is framed independently of framebuffer pixel damage.
        return [self discard:length];
    }
    unsigned char prefix[2];
    if (![self read:prefix count:2])
        return NO;
    NSUInteger size = Read16(prefix);
    if (size > 65535 || size < 2)
        return NO;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (![self read:data.mutableBytes count:size])
        return NO;
    if (encoding == 0x451) {
        // Version-5 layout starts with version, display selector and flags. Geometry
        // is carried in the first screen's backing/scaled bounds, not its identifier.
        const unsigned char *p = data.bytes;
        if (size < 66 || Read16(p) != 5) {
            _failure = [NSString stringWithFormat:@"Unsupported Apple display-layout format (version %u, size %lu).",
                                                  size >= 2 ? Read16(p) : 0, (unsigned long)size];
            return NO;
        }
        NSUInteger backingW = Read16(p + 36), backingH = Read16(p + 38), logicalW = Read16(p + 44),
                   logicalH = Read16(p + 46);
        if (!logicalW || !logicalH || logicalW > 3840 || logicalH > 2160 || !backingW || !backingH || backingW > 3840 ||
            backingH > 2160) {
            _failure =
                [NSString stringWithFormat:@"Invalid Apple display geometry (%lu × %lu logical, %lu × %lu backing).",
                                           (unsigned long)logicalW, (unsigned long)logicalH, (unsigned long)backingW,
                                           (unsigned long)backingH];
            return NO;
        }
        if (_width != backingW || _height != backingH)
            if (![self sizeWidth:backingW height:backingH])
                return NO;
        if (self.onAppleLayout)
            self.onAppleLayout(logicalW, logicalH, backingW, backingH);
        return [self armAppleUpdates];
    }
    return encoding == 0x455 || encoding == 0x456;
}
- (BOOL)frameUpdate {
    unsigned char header[3];
    if (![self read:header count:3])
        return NO;
    NSUInteger count = Read16(header + 1);
    if (count > 4096)
        return NO;
    BOOL resized = NO, damaged = NO, appleRearmed = NO;
    for (NSUInteger i = 0; i < count; i++) {
        unsigned char rect[12];
        if (![self read:rect count:12])
            return NO;
        NSUInteger x = Read16(rect), y = Read16(rect + 2), w = Read16(rect + 4), h = Read16(rect + 6);
        int32_t encoding = (int32_t)Read32(rect + 8);
        if (_apple && (encoding == 0x44f || encoding == 0x450 || encoding == 0x451 || encoding == 0x453 ||
                       encoding == 0x455 || encoding == 0x456)) {
            if (![self appleMetadata:encoding x:x y:y width:w height:h])
                return NO;
            appleRearmed |= encoding == 0x451;
            continue;
        }
        if (encoding == -223) {
            if (resized || ![self sizeWidth:w height:h])
                return NO;
            resized = YES;
            continue;
        }
        if (!w || !h || x + w > _width || y + h > _height)
            return NO;
        damaged = YES;
        if (encoding == 0) {
            if (![self rawX:x y:y width:w height:h])
                return NO;
        } else if (encoding == 5) {
            if (![self hextileX:x y:y width:w height:h])
                return NO;
        } else if (encoding == 6) {
            if (![self zlibX:x y:y width:w height:h])
                return NO;
        } else if (encoding == 1) {
            unsigned char source[4];
            if (![self read:source count:4])
                return NO;
            NSUInteger sx = Read16(source), sy = Read16(source + 2);
            if (sx + w > _width || sy + h > _height)
                return NO;
            unsigned char *pixels = _pixels.mutableBytes;
            for (NSUInteger row = 0; row < h; row++) {
                NSUInteger r = sy < y ? h - 1 - row : row;
                memmove(pixels + ((y + r) * _width + x) * 4, pixels + ((sy + r) * _width + sx) * 4, w * 4);
            }
        } else
            return NO;
    }
    if (damaged && ![self cancelled]) {
        if (self.onFrame)
            self.onFrame([_pixels copy], _width, _height, _width * 4);
        if (_apple && !_reportedFrame) {
            _reportedFrame = YES;
            [self status:@"connected" message:@"Apple virtual display connected (full quality)"];
        }
    }
    // Apple drops the update subscription during virtual-display/agent changes.
    // Both its vendor layout and standard DesktopSize notifications must re-arm.
    if (_apple && resized)
        return [self armAppleUpdates];
    // Full-quality TCP peers can require one request per framebuffer update,
    // even after accepting the Apple subscription. Keep the pull loop alive.
    return appleRearmed || [self requestFrame:!resized];
}
- (NSData *)key:(uint32_t)key pressed:(BOOL)pressed {
    unsigned char packet[8] = {4, pressed ? 1 : 0};
    Put32(packet + 4, key);
    return [NSData dataWithBytes:packet length:8];
}
- (void)enqueue:(NSData *)packet {
    @synchronized(self) {
        if (!_ready || _cancelled)
            return;
        if (_inputBytes + packet.length > 1048576) {
            _cancelled = YES;
            shutdown(_fd, SHUT_RDWR);
            return;
        }
        [_input addObject:packet];
        _inputBytes += packet.length;
    }
}
- (void)sendKeySym:(uint32_t)key pressed:(BOOL)pressed {
    [self enqueue:[self key:key pressed:pressed]];
}
- (void)sendPointerMask:(NSInteger)mask x:(NSInteger)x y:(NSInteger)y {
    unsigned char packet[6] = {5, (unsigned char)mask};
    Put16(packet + 2, (uint16_t)MAX(0, MIN(65535, x)));
    Put16(packet + 4, (uint16_t)MAX(0, MIN(65535, y)));
    [self enqueue:[NSData dataWithBytes:packet length:6]];
}
- (void)sendControlAltDelete {
    [self cancelTyping];
    NSMutableData *data = [NSMutableData data];
    for (NSNumber *key in @[ @0xffe3, @0xffe9, @0xffff ])
        [data appendData:[self key:key.unsignedIntValue pressed:YES]];
    for (NSNumber *key in @[ @0xffff, @0xffe9, @0xffe3 ])
        [data appendData:[self key:key.unsignedIntValue pressed:NO]];
    [self enqueue:data];
}
- (BOOL)typeText:(NSString *)text {
    NSMutableArray<NSNumber *> *keys = [NSMutableArray array];
    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\r"
                                  withString:@"\n"];
    if (normalized.length > 32768)
        return NO;
    for (NSUInteger i = 0; i < normalized.length; i++) {
        uint32_t scalar = [normalized characterAtIndex:i];
        if (scalar >= 0xd800 && scalar <= 0xdbff) {
            if (++i >= normalized.length)
                return NO;
            uint32_t low = [normalized characterAtIndex:i];
            if (low < 0xdc00 || low > 0xdfff)
                return NO;
            scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
        } else if (scalar >= 0xdc00 && scalar <= 0xdfff)
            return NO;
        if ((scalar < 32 && scalar != 10 && scalar != 9) || (scalar >= 127 && scalar <= 159))
            return NO;
        [keys addObject:@(KeySym(scalar))];
        if (keys.count > 16384)
            return NO;
    }
    @synchronized(self) {
        if (!_ready || _cancelled || _typing || !keys.count)
            return NO;
        _typing = keys;
        _typingIndex = 0;
        _nextKey = 0;
    }
    return YES;
}
- (void)cancelTyping {
    @synchronized(self) {
        _typing = nil;
    }
}
- (void)reportKeyboardInput {
    if (!_reportedKeyboard) {
        _reportedKeyboard = YES;
        if (self.onKeyboardInput)
            self.onKeyboardInput();
    }
}
- (BOOL)writeInput:(NSData *)packet {
    if (!_apple)
        return [self write:packet.bytes count:packet.length];
    if (packet.length && ((const unsigned char *)packet.bytes)[0] == 4 && packet.length % 8 == 0) {
        for (NSUInteger offset = 0; offset < packet.length; offset += 8)
            if (![_apple writeInput:[packet subdataWithRange:NSMakeRange(offset, 8)]])
                return NO;
        return YES;
    }
    return [_apple writeInput:packet];
}
- (BOOL)flushInput {
    NSData *resize;
    @synchronized(self) {
        resize = _pendingAppleResize;
        _pendingAppleResize = nil;
    }
    if (resize && ![self write:resize.bytes count:resize.length])
        return NO;
    NSArray<NSData *> *packets;
    NSNumber *typed = nil;
    BOOL typing;
    @synchronized(self) {
        packets = [_input copy];
        [_input removeAllObjects];
        _inputBytes = 0;
        if (_typing && FCWireGuardSocketTime() >= _nextKey) {
            typed = _typing[_typingIndex++];
            _nextKey = FCWireGuardSocketTime() + 0.005;
            if (_typingIndex == _typing.count)
                _typing = nil;
        }
        typing = _typing != nil;
    }
    for (NSData *packet in packets) {
        // TCP framebuffer input uses framebuffer pixels. The display agent
        // applies its own Retina conversion; dividing here scales twice.
        NSData *outgoing = packet;
        if (![self writeInput:outgoing])
            return NO;
        if (outgoing.length && ((const unsigned char *)outgoing.bytes)[0] == 4)
            [self reportKeyboardInput];
    }
    if (typed) {
        if (!_reportedTyping && self.onTyping)
            self.onTyping(YES);
        _reportedTyping = YES;
        NSData *down = [self key:typed.unsignedIntValue pressed:YES], *up = [self key:typed.unsignedIntValue
                                                                              pressed:NO];
        if (![self writeInput:down] || ![self writeInput:up])
            return NO;
        [self reportKeyboardInput];
    }
    if (_reportedTyping != typing) {
        _reportedTyping = typing;
        if (self.onTyping)
            self.onTyping(typing);
    }
    return YES;
}
- (void)connectHost:(NSString *)host port:(NSInteger)port username:(NSString *)username password:(NSString *)password {
    @synchronized(self) {
        if (_started)
            return;
        _started = YES;
    }
    dispatch_group_enter(FCVNCWorkers());
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
          self->_failure = @"VNC could not connect to the server.";
          [self status:@"connecting" message:@"Connecting to VNC…"];
          BOOL ok = [self dial:host port:port];
          if (ok) {
              [self status:@"authenticating" message:@"Negotiating VNC authentication…"];
              ok = [self authenticateHost:host username:username password:password];
          }
          if (ok)
              ok = [self initializeDesktopUsername:username password:password];
          if (ok) {
              @synchronized(self) {
                  self->_ready = !self->_cancelled;
              }
              [self status:self->_apple ? @"connecting" : @"connected"
                   message:self->_apple ? @"Waiting for Apple virtual-display pixels…" : @"VNC connected"];
              double firstFrameDeadline = FCWireGuardSocketTime() + 30;
              while (![self cancelled]) {
                  if (self->_apple && !self->_reportedFrame && FCWireGuardSocketTime() >= firstFrameDeadline) {
                      self->_failure = @"The Mac authenticated but did not deliver desktop pixels.";
                      ok = NO;
                      break;
                  }
                  @autoreleasepool {
                      if (![self flushInput]) {
                          ok = NO;
                          break;
                      }
                      struct pollfd p = {self->_fd, POLLIN, 0};
                      int ready = (self->_apple.hasBufferedBytes || (self->_tls && SSL_pending(self->_tls)))
                                      ? 1
                                      : poll(&p, 1, 10);
                      if (!ready || (ready < 0 && errno == EINTR))
                          continue;
                      if (ready < 0) {
                          ok = NO;
                          break;
                      }
                      unsigned char type;
                      if (![self read:&type count:1]) {
                          ok = NO;
                          break;
                      }
                      if (type == 0)
                          ok = [self frameUpdate];
                      else if (type == 2) { /* Bell: no remote sound negotiation. */
                      } else if (self->_apple && type == 0x14) {
                          unsigned char header[3];
                          ok = [self read:header count:3];
                          NSUInteger length = ok ? Read16(header + 1) : 0;
                          ok = ok && length <= 4096 && [self discard:length];
                      } else if (type == 3) {
                          unsigned char header[7];
                          ok = [self read:header count:7];
                          uint32_t size = ok ? Read32(header + 3) : 0;
                          ok = ok && size <= 1048576 && [self discard:size];
                      } else
                          ok = NO;
                      if (!ok)
                          break;
                  }
              }
          }
          BOOL cancelled = [self cancelled];
          self->_apple = nil;
          @synchronized(self) {
              self->_pendingAppleResize = nil;
              self->_ready = NO;
              self->_typing = nil;
              if (self->_fd >= 0) {
                  close(self->_fd);
                  self->_fd = -1;
              }
          }
          if (self->_tls) {
              SSL_free(self->_tls);
              self->_tls = NULL;
          }
          if (self->_context) {
              SSL_CTX_free(self->_context);
              self->_context = NULL;
          }
          if (self->_inflating) {
              inflateEnd(&self->_inflate);
              self->_inflating = NO;
          }
          self->_pixels = nil;
          if (self.onTyping)
              self.onTyping(NO);
          [self status:cancelled ? @"disconnected" : @"failed" message:cancelled ? @"Disconnected" : self->_failure];
      }
      dispatch_group_leave(FCVNCWorkers());
    });
}
@end
