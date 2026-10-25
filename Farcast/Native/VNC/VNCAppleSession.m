#import "VNCAppleSession.h"
#import "VNCAppleWire.h"
NSErrorDomain const FCVNCAppleSessionErrorDomain = @"com.peterpo.farcast.vnc.apple";
#import <openssl/bn.h>
#import <openssl/crypto.h>
#import <openssl/evp.h>
#import <openssl/rand.h>
#import <openssl/rsa.h>
#import <openssl/sha.h>
#import <openssl/srp.h>
#import <openssl/x509.h>

static void Add16(NSMutableData *d, NSUInteger n) {
    unsigned char p[2];
    FCVNCWrite16(p, n);
    [d appendBytes:p length:2];
}
static void Add32(NSMutableData *d, uint32_t n) {
    unsigned char p[4];
    FCVNCWrite32(p, n);
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
    return Take(d, offset, shortLength ? p[0] : FCVNCRead16(p));
}

@implementation FCVNCAppleSession {
    NSError *_error;
    EVP_MD_CTX *_sendDigest;
    NSMutableData *_inputBatch;
    BOOL _authenticationRejected, _encrypted, _desktopLoginRequested, _authenticated;
    unsigned char _wrapKey[16];
    EVP_CIPHER_CTX *_sendCipher, *_receiveCipher, *_inputCipher;
    uint64_t _sendSequence, _receiveSequence;
    NSData *_buffer;
    NSUInteger _offset;
}
- (instancetype)init {
    if ((self = [super init]))
        [self fail:FCVNCAppleSessionProtocolError message:@"Apple Screen Sharing negotiation failed."];
    return self;
}
- (void)dealloc {
    EVP_CIPHER_CTX_free(_sendCipher);
    EVP_CIPHER_CTX_free(_receiveCipher);
    EVP_CIPHER_CTX_free(_inputCipher);
    EVP_MD_CTX_free(_sendDigest);
    OPENSSL_cleanse(_wrapKey, sizeof(_wrapKey));
}
- (NSString *)failure {
    return _error.localizedDescription;
}
- (NSError *)error {
    return _error;
}
- (BOOL)fail:(FCVNCAppleSessionError)code message:(NSString *)message {
    _error = [NSError errorWithDomain:FCVNCAppleSessionErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey : message}];
    return NO;
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
    if (!n || n > 65536 || self.isCancelled()) {
        [self fail:FCVNCAppleSessionTransportError
            message:@"Apple protocol read was cancelled or exceeded its message bounds."];
        return nil;
    }
    NSMutableData *d = [NSMutableData dataWithLength:n];
    if (!self.readTransport(d.mutableBytes, n)) {
        [self fail:FCVNCAppleSessionTransportError message:@"Apple protocol transport ended while reading a message."];
        return nil;
    }
    return d;
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
    return self.writeTransport(d.bytes, d.length) ||
           [self fail:FCVNCAppleSessionTransportError
               message:@"Apple authentication transport ended while sending a message."];
}
- (NSData *)authFrame {
    [self fail:FCVNCAppleSessionTransportError
        message:@"Apple authentication ended while reading the SRP frame length."];
    NSData *prefix = [self transportData:4];
    if (!prefix)
        return nil;
    uint32_t n = FCVNCRead32(prefix.bytes);
    if (n == 6) {
        _authenticationRejected = YES;
        [self fail:FCVNCAppleSessionAuthenticationError
            message:@"The Mac rejected account authentication. Verify the account username and password."];
        return nil;
    }
    if (n < 9 || n > 8192) {
        [self fail:FCVNCAppleSessionProtocolError
            message:[NSString
                        stringWithFormat:@"Apple authentication returned an unsupported SRP frame length (%u).", n]];
        return nil;
    }
    [self fail:FCVNCAppleSessionTransportError message:@"Apple authentication ended while reading an SRP frame."];
    NSData *frame = [self transportData:n];
    if (!frame)
        return nil;
    const unsigned char *p = frame.bytes;
    // macOS 27 replies use version/type/u16 body-size/u32 payload-size.
    // Older captures describe a byte-step envelope; accept only exact lengths.
    if (n >= 10 && (FCVNCRead16(p) == 0 || FCVNCRead16(p) == 1 || FCVNCRead16(p) == 0x100) && FCVNCRead16(p + 2) == 2 &&
        FCVNCRead16(p + 4) == n - 6 && FCVNCRead32(p + 6) == n - 10)
        return [frame subdataWithRange:NSMakeRange(10, n - 10)];
    NSUInteger size = FCVNCRead32(p + 5);
    if (size != n - 9 || FCVNCRead32(p + 1) != size + 4) {
        [self fail:FCVNCAppleSessionProtocolError
            message:[NSString
                        stringWithFormat:
                            @"Apple SRP frame sizes differ (outer %u, version %u, type %u, nested %u, payload %lu).", n,
                            FCVNCRead16(p), FCVNCRead16(p + 2), FCVNCRead32(p + 1), (unsigned long)size]];
        return nil;
    }
    return [frame subdataWithRange:NSMakeRange(9, size)];
}
- (BOOL)negotiateRSA {
    [self fail:FCVNCAppleSessionProtocolError
        message:@"The server does not support Apple Screen Sharing RSA-SRP authentication."];
    NSData *banner = [self transportData:12];
    if (banner.length != 12)
        return NO;
    if (memcmp(banner.bytes, FCVNC_APPLE_BANNER, 12))
        return [self fail:FCVNCAppleSessionProtocolError
                  message:@"Apple RFB version mismatch; this client requires version 3.889."];
    if (!self.writeTransport(FCVNC_APPLE_BANNER, 12))
        return [self fail:FCVNCAppleSessionTransportError message:@"Apple version exchange could not be sent."];
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
    return YES;
}
- (EVP_PKEY *)approvedServerKey {
    [self fail:FCVNCAppleSessionProtocolError message:@"Apple Screen Sharing returned an invalid server public key."];
    NSData *keyHeader = [self transportData:4];
    if (!keyHeader)
        return NULL;
    uint32_t keyLength = FCVNCRead32(keyHeader.bytes);
    if (keyLength < 8 || keyLength > 4096)
        return NULL;
    NSData *response = [self transportData:keyLength];
    if (!response)
        return NULL;
    const unsigned char *rp = response.bytes;
    NSUInteger derLength = FCVNCRead16(rp + 4);
    if (derLength + 7 != keyLength)
        return NULL;
    NSData *der = [response subdataWithRange:NSMakeRange(6, derLength)];
    const unsigned char *cursor = der.bytes;
    EVP_PKEY *key = d2i_PUBKEY(NULL, &cursor, (long)der.length);
    if (!key || cursor != (const unsigned char *)der.bytes + der.length || !EVP_PKEY_is_a(key, "RSA") ||
        EVP_PKEY_get_bits(key) != 2048) {
        EVP_PKEY_free(key);
        return NULL;
    }
    NSData *digest = Digest(EVP_sha256(), @[ der ]);
    NSString *fingerprint = [@"SHA256:"
        stringByAppendingString:[[digest base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"="
                                                                                                     withString:@""]];
    [self fail:FCVNCAppleSessionIdentityError message:@"Apple Screen Sharing server identity was not approved."];
    if (!digest ||
        !self.approveIdentity(
            fingerprint, @"Apple Screen Sharing RSA public key. Verify this SHA256 fingerprint independently before "
                         @"entering account credentials. This identity is separate from VNC TLS certificates.") ||
        self.isCancelled()) {
        EVP_PKEY_free(key);
        return NULL;
    }
    return key;
}
- (NSData *)encryptIdentity:(NSData *)user key:(EVP_PKEY *)key {
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
    if (!ok)
        return nil;
    [encrypted increaseLengthBy:384];
    return encrypted;
}
// RFC-style SRP notation: N/g group, a/A client secret/public, B server
// public, x password exponent, u scrambler, k multiplier, S secret, K key,
// M1/M2 mutual proofs. Constant-time flags and cleansing remain local here.
- (NSArray<NSData *> *)proofsForChallenge:(NSData *)challenge password:(NSData *)pass {
    NSUInteger at = 1;
    NSData *nData = TakeAtom(challenge, &at, NO), *gData = TakeAtom(challenge, &at, NO),
           *salt = TakeAtom(challenge, &at, YES), *bData = TakeAtom(challenge, &at, NO),
           *iterationsData = Take(challenge, &at, 8), *options = TakeAtom(challenge, &at, NO);
    uint64_t iterations = 0;
    if (iterationsData)
        for (NSUInteger i = 0; i < 8; i++)
            iterations = (iterations << 8) | ((const unsigned char *)iterationsData.bytes)[i];
    [self fail:FCVNCAppleSessionProtocolError
        message:@"Apple authentication returned unsupported SRP parameters or options."];
    NSString *optionString = options ? [[NSString alloc] initWithData:options encoding:NSASCIIStringEncoding] : nil;
    if (!nData || !gData || !salt.length || salt.length > 64 || !bData || !iterations || iterations > 1000000 ||
        ![optionString isEqual:FCVNC_SRP_OPTIONS] || at != challenge.length)
        return nil;
    [self fail:FCVNCAppleSessionProtocolError
        message:@"Apple authentication returned an unsupported SRP group or public-value size."];
    SRP_gN *group = SRP_get_default_gN("4096");
    BIGNUM *N = BN_bin2bn(nData.bytes, (int)nData.length, NULL), *g = BN_bin2bn(gData.bytes, (int)gData.length, NULL),
           *B = BN_bin2bn(bData.bytes, (int)bData.length, NULL), *a = BN_secure_new(), *A = BN_new(),
           *x = BN_secure_new(), *k = BN_new(), *u = BN_new(), *gx = BN_new(), *base = BN_new(),
           *exponent = BN_secure_new(), *S = BN_secure_new();
    BN_CTX *ctx = BN_CTX_secure_new();
    NSMutableData *derived = [NSMutableData dataWithLength:128];
    NSData *K = nil, *M1 = nil, *M2 = nil, *publicA = nil;
    BOOL ok = group && N && g && B && a && A && x && k && u && gx && base && exponent && S && ctx &&
              BN_cmp(N, group->N) == 0 && BN_cmp(g, group->g) == 0 && nData.length == 512 && bData.length <= 512 &&
              !BN_is_zero(B) && BN_cmp(B, N) < 0;
    if (ok) {
        [self fail:FCVNCAppleSessionAuthenticationError
            message:@"Apple authentication could not compute its SRP proof."];
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
        return nil;
    return @[ publicA, M1, M2, options ];
}
- (BOOL)authenticateUsername:(NSString *)username password:(NSString *)password {
    [self fail:FCVNCAppleSessionInputError
        message:@"Apple Screen Sharing requires a Mac account username and password."];
    NSData *user = [username dataUsingEncoding:NSUTF8StringEncoding],
           *pass = [password dataUsingEncoding:NSUTF8StringEncoding];
    if (!user.length || user.length > 128 || pass.length > 4096)
        return NO;
    if (![self negotiateRSA])
        return NO;
    EVP_PKEY *key = [self approvedServerKey];
    if (!key)
        return NO;
    NSData *encrypted = [self encryptIdentity:user key:key];
    EVP_PKEY_free(key);
    if (!encrypted)
        return [self fail:FCVNCAppleSessionAuthenticationError
                  message:@"Apple account identity could not be encrypted."];
    [self fail:FCVNCAppleSessionProtocolError message:@"Apple Screen Sharing authentication exchange failed."];
    if (![self sendRSA:2 body:encrypted length:256])
        return NO;
    NSData *challenge = [self authFrame];
    if (!challenge)
        return NO;
    NSArray<NSData *> *proofs = [self proofsForChallenge:challenge password:pass];
    if (!proofs)
        return NO;
    NSData *publicA = proofs[0], *M1 = proofs[1], *M2 = proofs[2], *options = proofs[3];
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
    [self fail:FCVNCAppleSessionAuthenticationError message:@"Apple Screen Sharing authentication proof was rejected."];
    if (serverProof.length != M2.length || CRYPTO_memcmp(serverProof.bytes, M2.bytes, M2.length)) {
        _authenticationRejected = YES;
        return NO;
    }
    NSData *serverRandom = TakeAtom(final, &pos, YES), *empty = TakeAtom(final, &pos, NO),
           *reserved = Take(final, &pos, 4);
    if (serverRandom.length != 16 || !empty || !reserved || pos != final.length)
        return NO;
    NSData *result = [self transportData:4];
    if (!result || FCVNCRead32(result.bytes)) {
        _authenticationRejected = YES;
        return NO;
    }
    [self fail:FCVNCAppleSessionProtocolError message:@"Apple Screen Sharing sent invalid encrypted protocol data."];
    _authenticated = YES;
    return YES;
}
- (BOOL)rekey:(NSData *)payload {
    if (payload.length != 36)
        return [self fail:FCVNCAppleSessionProtocolError message:@"Apple session-key update has an invalid length."];
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
    // Input records fit on the stack. Unusually large control messages use
    // bounded heap storage; no count-dependent stack allocations are permitted.
    unsigned char smallPlain[512] = {0}, smallCipher[514], seq[4];
    unsigned char *plain = size <= sizeof(smallPlain) ? smallPlain : calloc(1, size);
    unsigned char *cipher = size <= sizeof(smallPlain) ? smallCipher : malloc(size + 2);
    if (!_sendDigest)
        _sendDigest = EVP_MD_CTX_new();
    BOOL ok = plain && cipher && _sendDigest;
    if (ok) {
        FCVNCWrite16(plain, count);
        memcpy(plain + 2, bytes, count);
        FCVNCWrite32(seq, (uint32_t)_sendSequence);
        unsigned int digestSize = 0;
        ok = EVP_DigestInit_ex(_sendDigest, EVP_sha1(), NULL) == 1 &&
             EVP_DigestUpdate(_sendDigest, seq, sizeof(seq)) == 1 &&
             EVP_DigestUpdate(_sendDigest, plain, size - 20) == 1 &&
             EVP_DigestFinal_ex(_sendDigest, plain + size - 20, &digestSize) == 1 && digestSize == 20;
    }
    if (ok) {
        int written = 0;
        FCVNCWrite16(cipher, size);
        ok = EVP_EncryptUpdate(_sendCipher, cipher + 2, &written, plain, (int)size) == 1 && written == size;
    }
    if (plain)
        OPENSSL_cleanse(plain, size);
    if (plain != smallPlain)
        free(plain);
    if (ok) {
        // A failed send is terminal; never retry uncertain CBC/sequence state.
        _sendSequence++;
        if (_inputBatch) {
            if (_inputBatch.length + size + 2 > 16384) {
                ok = self.writeTransport(_inputBatch.bytes, _inputBatch.length);
                _inputBatch.length = 0;
            }
            if (ok)
                [_inputBatch appendBytes:cipher length:size + 2];
        } else {
            ok = self.writeTransport(cipher, size + 2);
        }
    }
    if (cipher != smallCipher)
        free(cipher);
    return ok || [self fail:FCVNCAppleSessionTransportError message:@"Apple encrypted record could not be sent."];
}
- (BOOL)writeInputs:(NSArray<NSData *> *)events {
    if (!events.count)
        return YES;
    NSAssert(!_inputBatch, @"Input batching cannot reenter the VNC worker");
    _inputBatch = [NSMutableData dataWithCapacity:4096];
    BOOL ok = YES;
    for (NSData *event in events) {
        const unsigned char *bytes = event.bytes;
        NSUInteger stride = event.length && bytes[0] == 4 ? 8 : 6;
        if (!event.length || event.length % stride) {
            ok = NO;
            break;
        }
        for (NSUInteger offset = 0; ok && offset < event.length; offset += stride)
            ok = [self writeInputBytes:bytes + offset count:stride];
        if (!ok)
            break;
    }
    if (ok && _inputBatch.length)
        ok = self.writeTransport(_inputBatch.bytes, _inputBatch.length);
    _inputBatch = nil;
    return ok;
}
- (BOOL)writeInput:(NSData *)event {
    return [self writeInputBytes:event.bytes count:event.length];
}
- (BOOL)writeInputBytes:(const unsigned char *)p count:(NSUInteger)count {
    BOOL keyboard = count == 8 && p[0] == 4;
    BOOL pointer = count == 6 && p[0] == 5;
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
            NSUInteger n = FCVNCRead16(prefix.bytes);
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
            FCVNCWrite32(seq, (uint32_t)_receiveSequence);
            NSData *hash = Digest(
                EVP_sha1(), @[ [NSData dataWithBytes:seq length:4], [plain subdataWithRange:NSMakeRange(0, n - 20)] ]);
            NSUInteger body = FCVNCRead16(plain.bytes);
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
    if (width < 200 || height < 200 || width > 3840 / scale || height > 2160 / scale)
        return nil;
    NSMutableData *d =
        [NSMutableData dataWithLength:FCVNCDisplayHeaderSize + FCVNCDisplayInfoSize + FCVNCDisplayModeSize];
    unsigned char *p = d.mutableBytes;
    p[0] = 0x1d;
    FCVNCWrite16(p + 2, d.length - 4);
    FCVNCWrite16(p + 4, 1);
    FCVNCWrite16(p + 6, 1);
    unsigned char *display = p + FCVNCDisplayHeaderSize;
    FCVNCWrite16(display, FCVNCDisplayInfoSize + FCVNCDisplayModeSize);
    memcpy(display + 2, FCVNC_DISPLAY_NAME, sizeof(FCVNC_DISPLAY_NAME));
    FCVNCWrite32(display + FCVNCDisplayFlags, 1);
    FCVNCWrite32(display + FCVNCDisplayDepth, 4);
    float mmw = (float)width * 25.4f / 132, mmh = (float)height * 25.4f / 132;
    uint32_t fw, fh;
    memcpy(&fw, &mmw, 4);
    memcpy(&fh, &mmh, 4);
    FCVNCWrite32(display + FCVNCDisplayPhysicalWidth, fw);
    FCVNCWrite32(display + FCVNCDisplayPhysicalHeight, fh);
    FCVNCWrite32(display + FCVNCDisplayMaxWidth, 3840);
    FCVNCWrite32(display + FCVNCDisplayMaxHeight, 2160);
    FCVNCWrite16(display + FCVNCDisplayModeCount, 1);
    unsigned char *mode = display + FCVNCDisplayInfoSize;
    FCVNCWrite32(mode, (uint32_t)(width * scale));
    FCVNCWrite32(mode + 4, (uint32_t)(height * scale));
    FCVNCWrite32(mode + 8, (uint32_t)width);
    FCVNCWrite32(mode + 12, (uint32_t)height);
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
    if (info.length < 22 || FCVNCRead16(info.bytes) != 0 || !(FCVNCRead32((const unsigned char *)info.bytes + 2) & 4))
        return YES;
    _desktopLoginRequested = YES;
    [self fail:FCVNCAppleSessionDesktopError message:@"The Mac sent unsupported desktop-login capabilities."];
    const unsigned char *metadata = info.bytes;
    if (info.length < 98 || FCVNCRead16(metadata + 22) != 74 || FCVNCRead16(metadata + 24) != 1 ||
        !(FCVNCRead32(metadata + 26) & 4) || _encrypted || !_authenticated)
        return NO;
    NSData *user = [username dataUsingEncoding:NSUTF8StringEncoding],
           *pass = [password dataUsingEncoding:NSUTF8StringEncoding];
    [self fail:FCVNCAppleSessionDesktopError
        message:@"Apple automatic desktop login requires a username and password of at most 63 UTF-8 bytes each, "
                @"without embedded NUL characters."];
    if (!user.length || user.length >= 64 || pass.length >= 64 || memchr(user.bytes, 0, user.length) ||
        (pass.length && memchr(pass.bytes, 0, pass.length)))
        return NO;
    // RFBSelectSession v2, command 2. Each fixed-size credential field is
    // encrypted with the SRP-derived AES key, after mutual proof verification.
    // This is protocol login, never keyboard input into an unidentified screen.
    unsigned char packet[FCVNCDesktopLoginSize] = {0}, clear[128];
    FCVNCWrite16(packet, 200);
    FCVNCWrite16(packet + 2, 2);
    packet[8] = 2;
    memcpy(packet + 10, FCVNC_APP_NAME, sizeof(FCVNC_APP_NAME));
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
             EVP_EncryptUpdate(cipher, packet + FCVNCDesktopLoginCredentials, &count, clear, sizeof(clear)) == 1 &&
             count == sizeof(clear);
        EVP_CIPHER_CTX_free(cipher);
    }
    OPENSSL_cleanse(clear, sizeof(clear));
    [self fail:FCVNCAppleSessionDesktopError
        message:@"Apple desktop login ended before the Mac acknowledged the encrypted credentials."];
    ok = ok && !self.isCancelled() && self.writeTransport(packet, sizeof(packet));
    OPENSSL_cleanse(packet, sizeof(packet));
    if (!ok)
        return NO;
    NSData *prefix = [self transportData:2];
    NSUInteger size = prefix ? FCVNCRead16(prefix.bytes) : 0;
    if (size < 10 || size > 4096)
        return NO;
    NSData *reply = [self transportData:size];
    if (!reply)
        return NO;
    const unsigned char *p = reply.bytes;
    // Prefix was consumed separately: version and status are offsets 0 and 2.
    if (FCVNCRead16(p) != 1)
        return NO;
    if (p[2] != 2) {
        [self fail:FCVNCAppleSessionDesktopError
            message:@"The Mac did not accept automatic desktop login. Check the account and remote login policy."];
        return NO;
    }
    [self fail:FCVNCAppleSessionProtocolError message:@"Apple Screen Sharing sent invalid encrypted protocol data."];
    return YES;
}
- (BOOL)bootstrapWidth:(NSUInteger)width height:(NSUInteger)height retina:(BOOL)retina {
    // Bootstrap writes remain cleartext until the server's first rekey is consumed.
    // Version-1 ViewerInfo is a fixed 66-byte structure in the macOS 27
    // server dispatcher: version, app identifier, app/OS triples, command bitmap.
    unsigned char viewer[66] = {0x21, 0};
    FCVNCWrite16(viewer + 2, 62);
    FCVNCWrite16(viewer + 4, 1);
    NSArray<NSString *> *version = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
        componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MIN((NSUInteger)3, version.count); i++)
        FCVNCWrite32(viewer + 10 + i * 4, version[i].intValue);
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    FCVNCWrite32(viewer + 22, (uint32_t)os.majorVersion);
    FCVNCWrite32(viewer + 26, (uint32_t)os.minorVersion);
    FCVNCWrite32(viewer + 30, (uint32_t)os.patchVersion);
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
    if (p[0] != 0 || FCVNCRead16(p + 2) != 1 || FCVNCRead32(p + 12) != 0x44f)
        return NO;
    NSData *payload = [self transportData:36];
    if (![self rekey:payload])
        return NO;
    NSData *configuration = [FCVNCAppleSession displayWidth:width height:height retina:retina];
    return configuration && [self write:configuration.bytes count:configuration.length];
}
@end
