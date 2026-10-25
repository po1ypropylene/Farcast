#import "VNCAppleSession.h"
#import <openssl/bn.h>
#import <openssl/crypto.h>
#import <openssl/evp.h>
#import <openssl/rand.h>
#import <openssl/rsa.h>
#import <openssl/sha.h>
#import <openssl/srp.h>
#import <openssl/x509.h>

static uint16_t A16(const unsigned char *p) { return ((uint16_t)p[0] << 8) | p[1]; }
static uint32_t A32(const unsigned char *p) { return ((uint32_t)A16(p) << 16) | A16(p + 2); }
static void S16(unsigned char *p, NSUInteger v) {
    p[0] = v >> 8;
    p[1] = v;
}
static void S32(unsigned char *p, uint32_t v) {
    S16(p, v >> 16);
    S16(p + 2, v);
}
static void Add16(NSMutableData *d, NSUInteger n) {
    unsigned char p[2];
    S16(p, n);
    [d appendBytes:p length:2];
}
static void Add32(NSMutableData *d, uint32_t n) {
    unsigned char p[4];
    S32(p, n);
    [d appendBytes:p length:4];
}
static void Atom(NSMutableData *d, NSData *v, BOOL shortLength) {
    if (shortLength) {
        unsigned char n = (unsigned char)v.length;
        [d appendBytes:&n length:1];
    } else
        Add16(d, v.length);
    [d appendData:v];
}
static NSData *Digest(const EVP_MD *md, NSArray<NSData *> *parts) {
    EVP_MD_CTX *c = EVP_MD_CTX_new();
    unsigned char out[EVP_MAX_MD_SIZE];
    unsigned int n = 0;
    BOOL ok = c && EVP_DigestInit_ex(c, md, NULL) == 1;
    for (NSData *d in parts)
        ok = ok && EVP_DigestUpdate(c, d.bytes, d.length) == 1;
    ok = ok && EVP_DigestFinal_ex(c, out, &n) == 1;
    EVP_MD_CTX_free(c);
    return ok ? [NSData dataWithBytes:out length:n] : nil;
}
static NSMutableData *BNBytes(const BIGNUM *b, NSUInteger size) {
    NSMutableData *d = [NSMutableData dataWithLength:size];
    return BN_bn2binpad(b, d.mutableBytes, (int)size) == size ? d : nil;
}
static NSData *Take(NSData *data, NSUInteger *offset, NSUInteger size) {
    if (*offset > data.length || size > data.length - *offset)
        return nil;
    NSData *part = [data subdataWithRange:NSMakeRange(*offset, size)];
    *offset += size;
    return part;
}
static NSData *TakeAtom(NSData *d, NSUInteger *offset, BOOL shortLength) {
    NSData *prefix = Take(d, offset, shortLength ? 1 : 2);
    if (!prefix)
        return nil;
    const unsigned char *p = prefix.bytes;
    return Take(d, offset, shortLength ? p[0] : A16(p));
}

@implementation FCVNCAppleSession {
    NSString *_failure;
    BOOL _authenticationRejected, _encrypted, _desktopLoginRequested, _authenticated;
    unsigned char _wrapKey[16];
    EVP_CIPHER_CTX *_sendCipher, *_receiveCipher, *_inputCipher;
    uint64_t _sendSequence, _receiveSequence;
    NSData *_buffer;
    NSUInteger _offset;
}
- (instancetype)init {
    if ((self = [super init]))
        _failure = @"Apple Screen Sharing negotiation failed.";
    return self;
}
- (void)dealloc {
    EVP_CIPHER_CTX_free(_sendCipher);
    EVP_CIPHER_CTX_free(_receiveCipher);
    EVP_CIPHER_CTX_free(_inputCipher);
    OPENSSL_cleanse(_wrapKey, sizeof(_wrapKey));
}
- (NSString *)failure {
    return _failure;
}
- (BOOL)authenticationRejected {
    return _authenticationRejected;
}
- (BOOL)encrypted {
    return _encrypted;
}
- (BOOL)hasBufferedBytes {
    return _offset < _buffer.length;
}
- (NSData *)transportData:(NSUInteger)n {
    if (!n || n > 65536 || self.isCancelled())
        return nil;
    NSMutableData *d = [NSMutableData dataWithLength:n];
    return self.readTransport(d.mutableBytes, n) ? d : nil;
}
- (BOOL)sendRSA:(NSUInteger)type body:(NSData *)body length:(NSUInteger)length {
    if (body.length > 65525 || length > body.length)
        return NO;
    NSMutableData *d = [NSMutableData data];
    Add32(d, (uint32_t)body.length + 10);
    Add16(d, 0x100);
    [d appendBytes:"RSA1" length:4];
    Add16(d, type);
    Add16(d, length);
    [d appendData:body];
    return self.writeTransport(d.bytes, d.length);
}
- (NSData *)authFrame {
    _failure = @"Apple authentication ended while reading the SRP frame length.";
    NSData *prefix = [self transportData:4];
    if (!prefix)
        return nil;
    uint32_t n = A32(prefix.bytes);
    if (n == 6) {
        _authenticationRejected = YES;
        _failure = @"The Mac rejected account authentication. Verify the account username and password.";
        return nil;
    }
    if (n < 9 || n > 8192) {
        _failure =
            [NSString stringWithFormat:@"Apple authentication returned an unsupported SRP frame length (%u).", n];
        return nil;
    }
    _failure = @"Apple authentication ended while reading an SRP frame.";
    NSData *frame = [self transportData:n];
    if (!frame)
        return nil;
    const unsigned char *p = frame.bytes;
    // macOS 27 replies use version/type/u16 body-size/u32 payload-size.
    // Older captures describe a byte-step envelope; accept only exact lengths.
    if (n >= 10 && (A16(p) == 0 || A16(p) == 1 || A16(p) == 0x100) && A16(p + 2) == 2 && A16(p + 4) == n - 6 &&
        A32(p + 6) == n - 10)
        return [frame subdataWithRange:NSMakeRange(10, n - 10)];
    NSUInteger size = A32(p + 5);
    if (size != n - 9 || A32(p + 1) != size + 4) {
        _failure = [NSString
            stringWithFormat:@"Apple SRP frame sizes differ (outer %u, version %u, type %u, nested %u, payload %lu).",
                             n, A16(p), A16(p + 2), A32(p + 1), (unsigned long)size];
        return nil;
    }
    return [frame subdataWithRange:NSMakeRange(9, size)];
}
- (BOOL)authenticateUsername:(NSString *)username password:(NSString *)password {
    _failure = @"Apple Screen Sharing requires a Mac account username and password.";
    NSData *user = [username dataUsingEncoding:NSUTF8StringEncoding],
           *pass = [password dataUsingEncoding:NSUTF8StringEncoding];
    if (!user.length || user.length > 128 || pass.length > 4096)
        return NO;
    _failure = @"The server does not support Apple Screen Sharing RSA-SRP authentication.";
    NSData *banner = [self transportData:12];
    if (banner.length != 12 || memcmp(banner.bytes, "RFB 003.889\n", 12) || !self.writeTransport("RFB 003.889\n", 12))
        return NO;
    NSData *count = [self transportData:1];
    if (!count)
        return NO;
    NSData *types = [self transportData:*(const unsigned char *)count.bytes];
    BOOL offered = NO;
    for (NSUInteger i = 0; i < types.length; i++)
        offered |= ((const unsigned char *)types.bytes)[i] == 33;
    if (!offered)
        return NO;
    unsigned char choice = 33;
    if (!self.writeTransport(&choice, 1) || ![self sendRSA:0 body:[NSData data] length:0])
        return NO;
    _failure = @"Apple Screen Sharing returned an invalid server public key.";
    NSData *keyHeader = [self transportData:4];
    if (!keyHeader)
        return NO;
    uint32_t keyLength = A32(keyHeader.bytes);
    if (keyLength < 8 || keyLength > 4096)
        return NO;
    NSData *response = [self transportData:keyLength];
    if (!response)
        return NO;
    const unsigned char *rp = response.bytes;
    NSUInteger derLength = A16(rp + 4);
    if (derLength + 7 != keyLength)
        return NO;
    NSData *der = [response subdataWithRange:NSMakeRange(6, derLength)];
    const unsigned char *cursor = der.bytes;
    EVP_PKEY *key = d2i_PUBKEY(NULL, &cursor, (long)der.length);
    if (!key || cursor != (const unsigned char *)der.bytes + der.length || !EVP_PKEY_is_a(key, "RSA") ||
        EVP_PKEY_get_bits(key) != 2048) {
        EVP_PKEY_free(key);
        return NO;
    }
    NSData *digest = Digest(EVP_sha256(), @[ der ]);
    NSString *fingerprint = [@"SHA256:"
        stringByAppendingString:[[digest base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"="
                                                                                                     withString:@""]];
    _failure = @"Apple Screen Sharing server identity was not approved.";
    if (!digest ||
        !self.approveIdentity(
            fingerprint, @"Apple Screen Sharing RSA public key. Verify this SHA256 fingerprint independently before "
                         @"entering account credentials. This identity is separate from VNC TLS certificates.") ||
        self.isCancelled()) {
        EVP_PKEY_free(key);
        return NO;
    }
    NSMutableData *identity = [NSMutableData data];
    Add32(identity, (uint32_t)user.length + 7);
    Add32(identity, (uint32_t)user.length);
    [identity appendData:user];
    Add16(identity, 0);
    unsigned char zero = 0;
    [identity appendBytes:&zero length:1];
    EVP_PKEY_CTX *rsa = EVP_PKEY_CTX_new(key, NULL);
    NSMutableData *encrypted = [NSMutableData dataWithLength:256];
    size_t encryptedLength = 256;
    BOOL ok = rsa && EVP_PKEY_encrypt_init(rsa) > 0 && EVP_PKEY_CTX_set_rsa_padding(rsa, RSA_PKCS1_PADDING) > 0 &&
              EVP_PKEY_encrypt(rsa, encrypted.mutableBytes, &encryptedLength, identity.bytes, identity.length) > 0 &&
              encryptedLength == 256;
    EVP_PKEY_CTX_free(rsa);
    EVP_PKEY_free(key);
    if (!ok)
        return NO;
    [encrypted increaseLengthBy:384];
    _failure = @"Apple Screen Sharing authentication exchange failed.";
    if (![self sendRSA:2 body:encrypted length:256])
        return NO;
    NSData *challenge = [self authFrame];
    if (!challenge)
        return NO;
    NSUInteger at = 1;
    NSData *nData = TakeAtom(challenge, &at, NO), *gData = TakeAtom(challenge, &at, NO),
           *salt = TakeAtom(challenge, &at, YES), *bData = TakeAtom(challenge, &at, NO),
           *iterationsData = Take(challenge, &at, 8), *options = TakeAtom(challenge, &at, NO);
    uint64_t iterations = 0;
    if (iterationsData)
        for (NSUInteger i = 0; i < 8; i++)
            iterations = (iterations << 8) | ((const unsigned char *)iterationsData.bytes)[i];
    _failure = @"Apple authentication returned unsupported SRP parameters or options.";
    NSString *optionString = options ? [[NSString alloc] initWithData:options encoding:NSASCIIStringEncoding] : nil;
    if (!nData || !gData || !salt.length || salt.length > 64 || !bData || !iterations || iterations > 1000000 ||
        ![optionString isEqual:@"mda=SHA-512,replay_detection,conf+int=ChaCha20-Poly1305,kdf=SALTED-SHA512-PBKDF2"] ||
        at != challenge.length)
        return NO;
    _failure = @"Apple authentication returned an unsupported SRP group or public-value size.";
    SRP_gN *group = SRP_get_default_gN("4096");
    BIGNUM *N = BN_bin2bn(nData.bytes, (int)nData.length, NULL), *g = BN_bin2bn(gData.bytes, (int)gData.length, NULL),
           *B = BN_bin2bn(bData.bytes, (int)bData.length, NULL), *a = BN_secure_new(), *A = BN_new(),
           *x = BN_secure_new(), *k = BN_new(), *u = BN_new(), *gx = BN_new(), *base = BN_new(),
           *exponent = BN_secure_new(), *S = BN_secure_new();
    BN_CTX *ctx = BN_CTX_secure_new();
    NSMutableData *derived = [NSMutableData dataWithLength:128];
    NSData *K = nil, *M1 = nil, *M2 = nil, *publicA = nil;
    ok = group && N && g && B && a && A && x && k && u && gx && base && exponent && S && ctx &&
         BN_cmp(N, group->N) == 0 && BN_cmp(g, group->g) == 0 && nData.length == 512 && bData.length <= 512 &&
         !BN_is_zero(B) && BN_cmp(B, N) < 0;
    if (ok) {
        _failure = @"Apple authentication could not compute its SRP proof.";
        BN_set_flags(a, BN_FLG_CONSTTIME);
        BN_set_flags(x, BN_FLG_CONSTTIME);
        BN_set_flags(exponent, BN_FLG_CONSTTIME);
        ok = PKCS5_PBKDF2_HMAC(pass.bytes, (int)pass.length, salt.bytes, (int)salt.length, (int)iterations,
                               EVP_sha512(), 128, derived.mutableBytes) == 1 &&
             BN_priv_rand(a, 256, BN_RAND_TOP_ONE, BN_RAND_BOTTOM_ANY) == 1 &&
             BN_mod_exp_mont_consttime(A, g, a, N, ctx, NULL) == 1;
    }
    if (ok) {
        NSData *inner = Digest(EVP_sha512(), @[ [NSData dataWithBytes:":" length:1], derived ]);
        NSData *xd = inner ? Digest(EVP_sha512(), @[ salt, inner ]) : nil;
        NSData *kd = Digest(EVP_sha512(), @[ BNBytes(N, 512), BNBytes(g, 512) ]);
        publicA = BNBytes(A, 512);
        NSData *ud = publicA ? Digest(EVP_sha512(), @[ publicA, BNBytes(B, 512) ]) : nil;
        ok = xd && kd && ud && BN_bin2bn(xd.bytes, (int)xd.length, x) && BN_bin2bn(kd.bytes, (int)kd.length, k) &&
             BN_bin2bn(ud.bytes, (int)ud.length, u) && !BN_is_zero(u) &&
             BN_mod_exp_mont_consttime(gx, g, x, N, ctx, NULL) && BN_mod_mul(base, k, gx, N, ctx) &&
             BN_mod_sub(base, B, base, N, ctx) && BN_mul(exponent, u, x, ctx) && BN_add(exponent, exponent, a) &&
             BN_mod_exp_mont_consttime(S, base, exponent, N, ctx, NULL);
        if (ok) {
            K = Digest(EVP_sha512(), @[ BNBytes(S, 512) ]);
            NSData *hn = Digest(EVP_sha512(), @[ nData ]), *hg = Digest(EVP_sha512(), @[ BNBytes(g, 512) ]),
                   *hi = Digest(EVP_sha512(), @[ [NSData data] ]);
            NSMutableData * xor = [hn mutableCopy];
            for (NSUInteger i = 0; i < xor.length; i++)
                ((unsigned char *)xor.mutableBytes)[i] ^= ((const unsigned char *)hg.bytes)[i];
            M1 = Digest(EVP_sha512(), @[ xor, hi, salt, publicA, BNBytes(B, 512), K ]);
            M2 = Digest(EVP_sha512(), @[ publicA, M1, K ]);
            NSData *wrap = Digest(EVP_sha256(), @[ K ]);
            if (wrap.length == 32) {
                memcpy(_wrapKey, wrap.bytes, 16);
            } else
                ok = NO;
        }
    }
    OPENSSL_cleanse(derived.mutableBytes, derived.length);
    BN_clear_free(N);
    BN_clear_free(g);
    BN_clear_free(B);
    BN_clear_free(a);
    BN_clear_free(A);
    BN_clear_free(x);
    BN_clear_free(k);
    BN_clear_free(u);
    BN_clear_free(gx);
    BN_clear_free(base);
    BN_clear_free(exponent);
    BN_clear_free(S);
    BN_CTX_free(ctx);
    if (!ok || self.isCancelled())
        return NO;
    unsigned char random[16];
    if (RAND_bytes(random, sizeof(random)) != 1)
        return NO;
    NSMutableData *proof = [NSMutableData data];
    Atom(proof, publicA, NO);
    Atom(proof, M1, YES);
    Atom(proof, options, NO);
    Atom(proof, [NSData dataWithBytes:random length:16], YES);
    NSMutableData *body = [NSMutableData data];
    Add16(body, 0);
    Add16(body, proof.length);
    [body appendData:proof];
    if (![self sendRSA:2 body:body length:body.length])
        return NO;
    NSData *final = [self authFrame];
    if (!final)
        return NO;
    NSUInteger pos = 0;
    NSData *serverProof = final ? TakeAtom(final, &pos, YES) : nil;
    _failure = @"Apple Screen Sharing authentication proof was rejected.";
    if (serverProof.length != M2.length || CRYPTO_memcmp(serverProof.bytes, M2.bytes, M2.length)) {
        _authenticationRejected = YES;
        return NO;
    }
    NSData *serverRandom = TakeAtom(final, &pos, YES), *empty = TakeAtom(final, &pos, NO),
           *reserved = Take(final, &pos, 4);
    if (serverRandom.length != 16 || !empty || !reserved || pos != final.length)
        return NO;
    NSData *result = [self transportData:4];
    if (!result || A32(result.bytes)) {
        _authenticationRejected = YES;
        return NO;
    }
    _failure = @"Apple Screen Sharing sent invalid encrypted protocol data.";
    _authenticated = YES;
    return YES;
}
- (BOOL)rekey:(NSData *)payload {
    if (payload.length != 36)
        return NO;
    EVP_CIPHER_CTX *ecb = EVP_CIPHER_CTX_new();
    unsigned char clear[32];
    int n = 0;
    BOOL ok = ecb && EVP_DecryptInit_ex(ecb, EVP_aes_128_ecb(), NULL, _wrapKey, NULL) == 1 &&
              EVP_CIPHER_CTX_set_padding(ecb, 0) == 1 &&
              EVP_DecryptUpdate(ecb, clear, &n, (const unsigned char *)payload.bytes + 4, 32) == 1 && n == 32;
    EVP_CIPHER_CTX_free(ecb);
    if (ok) {
        if (!_sendCipher)
            _sendCipher = EVP_CIPHER_CTX_new();
        if (!_receiveCipher)
            _receiveCipher = EVP_CIPHER_CTX_new();
        if (!_inputCipher)
            _inputCipher = EVP_CIPHER_CTX_new();
        ok = _sendCipher && _receiveCipher && _inputCipher &&
             EVP_EncryptInit_ex(_inputCipher, EVP_aes_128_ecb(), NULL, clear, NULL) == 1 &&
             EVP_CIPHER_CTX_set_padding(_inputCipher, 0) == 1 &&
             EVP_EncryptInit_ex(_sendCipher, EVP_aes_128_cbc(), NULL, clear, clear + 16) == 1 &&
             EVP_DecryptInit_ex(_receiveCipher, EVP_aes_128_cbc(), NULL, clear, clear + 16) == 1 &&
             EVP_CIPHER_CTX_set_padding(_sendCipher, 0) == 1 && EVP_CIPHER_CTX_set_padding(_receiveCipher, 0) == 1;
        if (ok) {
            memcpy(_wrapKey, clear, 16);
            _encrypted = YES;
        }
    }
    OPENSSL_cleanse(clear, sizeof(clear));
    return ok;
}
- (BOOL)write:(const void *)bytes count:(NSUInteger)count {
    if (!_encrypted)
        return self.writeTransport(bytes, count);
    if (!count || count > 65498 || _sendSequence > UINT32_MAX || self.isCancelled())
        return NO;
    NSUInteger size = (count + 22 + 15) & ~(NSUInteger)15;
    NSMutableData *plain = [NSMutableData dataWithLength:size], *cipher = [NSMutableData dataWithLength:size + 2];
    unsigned char *p = plain.mutableBytes;
    S16(p, count);
    memcpy(p + 2, bytes, count);
    unsigned char seq[4];
    S32(seq, (uint32_t)_sendSequence);
    NSData *hash = Digest(EVP_sha1(),
                          @[ [NSData dataWithBytes:seq length:4], [plain subdataWithRange:NSMakeRange(0, size - 20)] ]);
    if (hash.length != 20)
        return NO;
    memcpy(p + size - 20, hash.bytes, 20);
    int written = 0;
    S16(cipher.mutableBytes, size);
    BOOL ok = EVP_EncryptUpdate(_sendCipher, (unsigned char *)cipher.mutableBytes + 2, &written, p, (int)size) == 1 &&
              written == size;
    OPENSSL_cleanse(p, size);
    if (!ok)
        return NO;
    _sendSequence++;
    return self.writeTransport(cipher.bytes, cipher.length);
}
- (BOOL)writeInput:(NSData *)event {
    const unsigned char *p = event.bytes;
    BOOL keyboard = event.length == 8 && p[0] == 4;
    BOOL pointer = event.length == 6 && p[0] == 5;
    if (!_authenticated || !_encrypted || (!keyboard && !pointer))
        return NO;
    // Apple mandates ECB here, CBC/SHA-1 records and RSA PKCS#1 v1.5 at
    // authentication. These are wire requirements, not general crypto choices.
    // All writes/rekeys run on the owning VNC worker.
    // Apple input has a separate ECB envelope inside the authenticated record.
    // The event cipher follows the current session key after every rekey.
    unsigned char clear[16] = {0}, packet[18] = {0x10, pointer ? 1 : 0};
    if (keyboard) {
        clear[0] = 0xff;
        clear[1] = p[1];
        memcpy(clear + 2, p + 4, 4);
    } else {
        clear[10] = 0xff;
        clear[11] = p[1];
        memcpy(clear + 12, p + 2, 4);
    }
    int n = 0;
    BOOL ok = _inputCipher && EVP_EncryptUpdate(_inputCipher, packet + 2, &n, clear, sizeof(clear)) == 1 &&
              n == sizeof(clear);
    OPENSSL_cleanse(clear, sizeof(clear));
    return ok && [self write:packet count:sizeof(packet)];
}
- (BOOL)read:(void *)bytes count:(NSUInteger)count {
    if (!_encrypted)
        return self.readTransport(bytes, count);
    NSUInteger done = 0;
    while (done < count && !self.isCancelled()) {
        if (_offset == _buffer.length) {
            if (_receiveSequence > UINT32_MAX)
                return NO;
            NSData *prefix = [self transportData:2];
            if (!prefix)
                return NO;
            NSUInteger n = A16(prefix.bytes);
            if (n < 32 || n % 16)
                return NO;
            NSData *cipher = [self transportData:n];
            if (!cipher)
                return NO;
            NSMutableData *plain = [NSMutableData dataWithLength:n];
            int written = 0;
            if (EVP_DecryptUpdate(_receiveCipher, plain.mutableBytes, &written, cipher.bytes, (int)n) != 1 ||
                written != n)
                return NO;
            unsigned char seq[4];
            S32(seq, (uint32_t)_receiveSequence);
            NSData *hash = Digest(
                EVP_sha1(), @[ [NSData dataWithBytes:seq length:4], [plain subdataWithRange:NSMakeRange(0, n - 20)] ]);
            NSUInteger body = A16(plain.bytes);
            if (!body || body > n - 22 || n - body - 22 > 15 || hash.length != 20 ||
                CRYPTO_memcmp(hash.bytes, (const unsigned char *)plain.bytes + n - 20, 20)) {
                OPENSSL_cleanse(plain.mutableBytes, plain.length);
                return NO;
            }
            _buffer = [plain subdataWithRange:NSMakeRange(2, body)];
            _offset = 0;
            _receiveSequence++;
            OPENSSL_cleanse(plain.mutableBytes, plain.length);
        }
        NSUInteger n = MIN(count - done, _buffer.length - _offset);
        memcpy((unsigned char *)bytes + done, (const unsigned char *)_buffer.bytes + _offset, n);
        _offset += n;
        done += n;
    }
    return done == count;
}
+ (NSData *)displayWidth:(NSUInteger)width height:(NSUInteger)height retina:(BOOL)retina {
    NSUInteger scale = retina ? 2 : 1;
    if (width < 200 || height < 200 || width * scale > 3840 || height * scale > 2160)
        return nil;
    NSMutableData *d = [NSMutableData dataWithLength:12 + 0x9c + 28];
    unsigned char *p = d.mutableBytes;
    p[0] = 0x1d;
    S16(p + 2, d.length - 4);
    S16(p + 4, 1);
    S16(p + 6, 1);
    unsigned char *display = p + 12;
    S16(display, 0x9c + 28);
    memcpy(display + 2, "Farcast Virtual Display", 23);
    S32(display + 0x7a, 1);
    S32(display + 0x7e, 4);
    float mmw = (float)width * 25.4f / 132, mmh = (float)height * 25.4f / 132;
    uint32_t fw, fh;
    memcpy(&fw, &mmw, 4);
    memcpy(&fh, &mmh, 4);
    S32(display + 0x82, fw);
    S32(display + 0x86, fh);
    S32(display + 0x8a, 3840);
    S32(display + 0x8e, 2160);
    S16(display + 0x9a, 1);
    unsigned char *mode = display + 0x9c;
    S32(mode, (uint32_t)(width * scale));
    S32(mode + 4, (uint32_t)(height * scale));
    S32(mode + 8, (uint32_t)width);
    S32(mode + 12, (uint32_t)height);
    double hz = 60;
    uint64_t bits;
    memcpy(&bits, &hz, 8);
    for (int i = 0; i < 8; i++)
        mode[16 + i] = bits >> (56 - i * 8);
    return d;
}
- (BOOL)desktopLoginRequested {
    return _desktopLoginRequested;
}
- (BOOL)selectDesktopWithServerInfo:(NSData *)info username:(NSString *)username password:(NSString *)password {
    // Apple puts its capability header before the printable ServerInit name.
    // Only a server-requested selection phase accepts this non-RFB exchange.
    if (info.length < 22 || A16(info.bytes) != 0 || !(A32((const unsigned char *)info.bytes + 2) & 4))
        return YES;
    _desktopLoginRequested = YES;
    _failure = @"The Mac sent unsupported desktop-login capabilities.";
    const unsigned char *metadata = info.bytes;
    if (info.length < 98 || A16(metadata + 22) != 74 || A16(metadata + 24) != 1 || !(A32(metadata + 26) & 4) ||
        _encrypted || !_authenticated)
        return NO;
    NSData *user = [username dataUsingEncoding:NSUTF8StringEncoding],
           *pass = [password dataUsingEncoding:NSUTF8StringEncoding];
    _failure = @"Apple automatic desktop login requires a username and password of at most 63 UTF-8 bytes each, "
               @"without embedded NUL characters.";
    if (!user.length || user.length >= 64 || pass.length >= 64 || memchr(user.bytes, 0, user.length) ||
        (pass.length && memchr(pass.bytes, 0, pass.length)))
        return NO;
    // RFBSelectSession v2, command 2. Each fixed-size credential field is
    // encrypted with the SRP-derived AES key, after mutual proof verification.
    // This is protocol login, never keyboard input into an unidentified screen.
    unsigned char packet[202] = {0}, clear[128];
    S16(packet, 200);
    S16(packet + 2, 2);
    packet[8] = 2;
    memcpy(packet + 10, "Farcast", 8);
    BOOL ok = RAND_bytes(clear, sizeof(clear)) == 1;
    if (ok) {
        memcpy(clear, user.bytes, user.length);
        clear[user.length] = 0;
        memcpy(clear + 64, pass.bytes, pass.length);
        clear[64 + pass.length] = 0;
        EVP_CIPHER_CTX *cipher = EVP_CIPHER_CTX_new();
        int count = 0;
        ok = cipher && EVP_EncryptInit_ex(cipher, EVP_aes_128_ecb(), NULL, _wrapKey, NULL) == 1 &&
             EVP_CIPHER_CTX_set_padding(cipher, 0) == 1 &&
             EVP_EncryptUpdate(cipher, packet + 74, &count, clear, sizeof(clear)) == 1 && count == sizeof(clear);
        EVP_CIPHER_CTX_free(cipher);
    }
    OPENSSL_cleanse(clear, sizeof(clear));
    _failure = @"Apple desktop login ended before the Mac acknowledged the encrypted credentials.";
    ok = ok && !self.isCancelled() && self.writeTransport(packet, sizeof(packet));
    OPENSSL_cleanse(packet, sizeof(packet));
    if (!ok)
        return NO;
    NSData *prefix = [self transportData:2];
    NSUInteger size = prefix ? A16(prefix.bytes) : 0;
    if (size < 10 || size > 4096)
        return NO;
    NSData *reply = [self transportData:size];
    if (!reply)
        return NO;
    const unsigned char *p = reply.bytes;
    // Prefix was consumed separately: version and status are offsets 0 and 2.
    if (A16(p) != 1)
        return NO;
    if (p[2] != 2) {
        _failure = @"The Mac did not accept automatic desktop login. Check the account and remote login policy.";
        return NO;
    }
    _failure = @"Apple Screen Sharing sent invalid encrypted protocol data.";
    return YES;
}
- (BOOL)bootstrapWidth:(NSUInteger)width height:(NSUInteger)height retina:(BOOL)retina {
    // Bootstrap writes remain cleartext until the server's first rekey is consumed.
    // Version-1 ViewerInfo is a fixed 66-byte structure in the macOS 27
    // server dispatcher: version, app identifier, app/OS triples, command bitmap.
    unsigned char viewer[66] = {0x21, 0};
    S16(viewer + 2, 62);
    S16(viewer + 4, 1);
    NSArray<NSString *> *version = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
        componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MIN((NSUInteger)3, version.count); i++)
        S32(viewer + 10 + i * 4, version[i].intValue);
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    S32(viewer + 22, (uint32_t)os.majorVersion);
    S32(viewer + 26, (uint32_t)os.minorVersion);
    S32(viewer + 30, (uint32_t)os.patchVersion);
    for (NSNumber *command in @[ @0, @2, @3, @20 ]) {
        NSUInteger bit = command.unsignedIntegerValue;
        viewer[34 + bit / 8] |= 0x80 >> (bit % 8);
    }
    if (!self.writeTransport(viewer, sizeof(viewer)))
        return NO;
    unsigned char start[] = {0x12, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 1};
    unsigned char stop[] = {0x12, 0, 0, 2, 0, 1, 0, 0};
    if (!self.writeTransport(start, sizeof(start)) || !self.writeTransport(stop, sizeof(stop)))
        return NO;
    NSData *update = [self transportData:16];
    if (!update)
        return NO;
    const unsigned char *p = update.bytes;
    if (p[0] != 0 || A16(p + 2) != 1 || A32(p + 12) != 0x44f)
        return NO;
    NSData *payload = [self transportData:36];
    if (![self rekey:payload])
        return NO;
    NSData *configuration = [FCVNCAppleSession displayWidth:width height:height retina:retina];
    return configuration && [self write:configuration.bytes count:configuration.length];
}
@end
