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

static void AppendUInt16(NSMutableData *data, NSUInteger value) {
    unsigned char bytes[2];
    FCVNCWrite16(bytes, value);
    [data appendBytes:bytes length:2];
}
static void AppendUInt32(NSMutableData *data, uint32_t value) {
    unsigned char bytes[4];
    FCVNCWrite32(bytes, value);
    [data appendBytes:bytes length:4];
}
static void AppendLengthPrefixedData(NSMutableData *data, NSData *value, BOOL shortLength) {
    if (shortLength) {
        unsigned char lengthByte = (unsigned char)value.length;
        [data appendBytes:&lengthByte length:1];
    } else
        AppendUInt16(data, value.length);
    [data appendData:value];
}
static NSData *Digest(const EVP_MD *md, NSArray<NSData *> *parts) {
    EVP_MD_CTX *context = EVP_MD_CTX_new();
    unsigned char digestBytes[EVP_MAX_MD_SIZE];
    unsigned int digestLength = 0;
    BOOL ok = context && EVP_DigestInit_ex(context, md, NULL) == 1;
    for (NSData *data in parts)
        ok = ok && EVP_DigestUpdate(context, data.bytes, data.length) == 1;
    ok = ok && EVP_DigestFinal_ex(context, digestBytes, &digestLength) == 1;
    EVP_MD_CTX_free(context);
    return ok ? [NSData dataWithBytes:digestBytes length:digestLength] : nil;
}
static NSMutableData *PaddedBigNumberData(const BIGNUM *number, NSUInteger size) {
    NSMutableData *data = [NSMutableData dataWithLength:size];
    return BN_bn2binpad(number, data.mutableBytes, (int)size) == size ? data : nil;
}
static NSData *ReadData(NSData *data, NSUInteger *offset, NSUInteger size) {
    if (*offset > data.length || size > data.length - *offset)
        return nil;
    NSData *part = [data subdataWithRange:NSMakeRange(*offset, size)];
    *offset += size;
    return part;
}
static NSData *ReadLengthPrefixedData(NSData *data, NSUInteger *offset, BOOL shortLength) {
    NSData *prefix = ReadData(data, offset, shortLength ? 1 : 2);
    if (!prefix)
        return nil;
    const unsigned char *bytes = prefix.bytes;
    return ReadData(data, offset, shortLength ? bytes[0] : FCVNCRead16(bytes));
}

// Named results keep the proof exchange independent of array positions.
@interface FCVNCAppleSRPProofs : NSObject
@property(nonatomic, copy) NSData *clientPublicBytes;
@property(nonatomic, copy) NSData *clientProof;
@property(nonatomic, copy) NSData *expectedServerProof;
@property(nonatomic, copy) NSData *options;
@end
@implementation FCVNCAppleSRPProofs
@end

@implementation FCVNCAppleSession {
    NSError *_error;
    EVP_MD_CTX *_sendDigest;
    NSMutableData *_inputBatch;
    BOOL _authenticationRejected, _encrypted, _desktopLoginRequested, _authenticated;
    unsigned char _wrapKey[16];
    EVP_CIPHER_CTX *_sendCipher, *_receiveCipher, *_inputCipher;
    uint64_t _sendSequence, _receiveSequence;
    NSData *_receivePayload;
    NSUInteger _receivePayloadOffset;
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
    return _receivePayloadOffset < _receivePayload.length;
}
- (NSData *)transportData:(NSUInteger)byteCount {
    if (!byteCount || byteCount > 65536 || self.isCancelled()) {
        [self fail:FCVNCAppleSessionTransportError
            message:@"Apple protocol read was cancelled or exceeded its message bounds."];
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:byteCount];
    if (!self.readTransport(data.mutableBytes, byteCount)) {
        [self fail:FCVNCAppleSessionTransportError message:@"Apple protocol transport ended while reading a message."];
        return nil;
    }
    return data;
}
- (BOOL)sendRSA:(NSUInteger)type body:(NSData *)body length:(NSUInteger)length {
    if (body.length > 65525 || length > body.length)
        return NO;
    NSMutableData *frame = [NSMutableData data];
    AppendUInt32(frame, (uint32_t)body.length + 10);
    AppendUInt16(frame, 0x100);
    [frame appendBytes:"RSA1" length:4];
    AppendUInt16(frame, type);
    AppendUInt16(frame, length);
    [frame appendData:body];
    return self.writeTransport(frame.bytes, frame.length) ||
           [self fail:FCVNCAppleSessionTransportError
               message:@"Apple authentication transport ended while sending a message."];
}
- (NSData *)authFrame {
    [self fail:FCVNCAppleSessionTransportError
        message:@"Apple authentication ended while reading the SRP frame length."];
    NSData *prefix = [self transportData:4];
    if (!prefix)
        return nil;
    uint32_t frameLength = FCVNCRead32(prefix.bytes);
    if (frameLength == 6) {
        _authenticationRejected = YES;
        [self fail:FCVNCAppleSessionAuthenticationError
            message:@"The Mac rejected account authentication. Verify the account username and password."];
        return nil;
    }
    if (frameLength < 9 || frameLength > 8192) {
        [self fail:FCVNCAppleSessionProtocolError
            message:[NSString stringWithFormat:@"Apple authentication returned an unsupported SRP frame length (%u).",
                                               frameLength]];
        return nil;
    }
    [self fail:FCVNCAppleSessionTransportError message:@"Apple authentication ended while reading an SRP frame."];
    NSData *frame = [self transportData:frameLength];
    if (!frame)
        return nil;
    const unsigned char *frameBytes = frame.bytes;
    // macOS 27 replies use version/type/u16 body-size/u32 payload-size.
    // Older captures describe a byte-step envelope; accept only exact lengths.
    if (frameLength >= 10 &&
        (FCVNCRead16(frameBytes) == 0 || FCVNCRead16(frameBytes) == 1 || FCVNCRead16(frameBytes) == 0x100) &&
        FCVNCRead16(frameBytes + 2) == 2 && FCVNCRead16(frameBytes + 4) == frameLength - 6 &&
        FCVNCRead32(frameBytes + 6) == frameLength - 10)
        return [frame subdataWithRange:NSMakeRange(10, frameLength - 10)];
    NSUInteger payloadLength = FCVNCRead32(frameBytes + 5);
    if (payloadLength != frameLength - 9 || FCVNCRead32(frameBytes + 1) != payloadLength + 4) {
        [self fail:FCVNCAppleSessionProtocolError
            message:[NSString
                        stringWithFormat:
                            @"Apple SRP frame sizes differ (outer %u, version %u, type %u, nested %u, payload %lu).",
                            frameLength, FCVNCRead16(frameBytes), FCVNCRead16(frameBytes + 2),
                            FCVNCRead32(frameBytes + 1), (unsigned long)payloadLength]];
        return nil;
    }
    return [frame subdataWithRange:NSMakeRange(9, payloadLength)];
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
    const unsigned char *responseBytes = response.bytes;
    NSUInteger derLength = FCVNCRead16(responseBytes + 4);
    if (derLength + 7 != keyLength)
        return NULL;
    NSData *encodedPublicKey = [response subdataWithRange:NSMakeRange(6, derLength)];
    const unsigned char *cursor = encodedPublicKey.bytes;
    EVP_PKEY *key = d2i_PUBKEY(NULL, &cursor, (long)encodedPublicKey.length);
    if (!key || cursor != (const unsigned char *)encodedPublicKey.bytes + encodedPublicKey.length ||
        !EVP_PKEY_is_a(key, "RSA") || EVP_PKEY_get_bits(key) != 2048) {
        EVP_PKEY_free(key);
        return NULL;
    }
    NSData *digest = Digest(EVP_sha256(), @[ encodedPublicKey ]);
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
- (NSData *)encryptIdentity:(NSData *)usernameBytes key:(EVP_PKEY *)key {
    NSMutableData *identity = [NSMutableData data];
    AppendUInt32(identity, (uint32_t)usernameBytes.length + 7);
    AppendUInt32(identity, (uint32_t)usernameBytes.length);
    [identity appendData:usernameBytes];
    AppendUInt16(identity, 0);
    unsigned char zero = 0;
    [identity appendBytes:&zero length:1];
    EVP_PKEY_CTX *encryptionContext = EVP_PKEY_CTX_new(key, NULL);
    NSMutableData *encrypted = [NSMutableData dataWithLength:256];
    size_t encryptedLength = 256;
    BOOL ok = encryptionContext && EVP_PKEY_encrypt_init(encryptionContext) > 0 &&
              EVP_PKEY_CTX_set_rsa_padding(encryptionContext, RSA_PKCS1_PADDING) > 0 &&
              EVP_PKEY_encrypt(encryptionContext, encrypted.mutableBytes, &encryptedLength, identity.bytes,
                               identity.length) > 0 &&
              encryptedLength == 256;
    EVP_PKEY_CTX_free(encryptionContext);
    if (!ok)
        return nil;
    [encrypted increaseLengthBy:384];
    return encrypted;
}
// SRP notation: modulus/generator = N/g, clientPrivate/clientPublic = a/A,
// serverPublic = B, passwordExponent = x, multiplier = k, scrambler = u,
// sharedSecret = S, sessionKey = K, clientProof/expectedServerProof = M1/M2.
// The server's group fields keep OpenSSL's N/g names. Secret BIGNUMs retain
// their secure allocation, constant-time operations and explicit cleanup.
- (FCVNCAppleSRPProofs *)proofsForChallenge:(NSData *)challenge password:(NSData *)passwordBytes {
    NSUInteger challengeOffset = 1;
    NSData *modulusBytes = ReadLengthPrefixedData(challenge, &challengeOffset, NO),
           *generatorBytes = ReadLengthPrefixedData(challenge, &challengeOffset, NO),
           *salt = ReadLengthPrefixedData(challenge, &challengeOffset, YES),
           *serverPublicBytes = ReadLengthPrefixedData(challenge, &challengeOffset, NO),
           *iterationsData = ReadData(challenge, &challengeOffset, 8),
           *options = ReadLengthPrefixedData(challenge, &challengeOffset, NO);
    uint64_t iterations = 0;
    if (iterationsData)
        for (NSUInteger i = 0; i < 8; i++)
            iterations = (iterations << 8) | ((const unsigned char *)iterationsData.bytes)[i];
    [self fail:FCVNCAppleSessionProtocolError
        message:@"Apple authentication returned unsupported SRP parameters or options."];
    NSString *optionString = options ? [[NSString alloc] initWithData:options encoding:NSASCIIStringEncoding] : nil;
    if (!modulusBytes || !generatorBytes || !salt.length || salt.length > 64 || !serverPublicBytes || !iterations ||
        iterations > 1000000 || ![optionString isEqual:FCVNC_SRP_OPTIONS] || challengeOffset != challenge.length)
        return nil;
    [self fail:FCVNCAppleSessionProtocolError
        message:@"Apple authentication returned an unsupported SRP group or public-value size."];
    SRP_gN *group = SRP_get_default_gN("4096");
    BIGNUM *modulus = BN_bin2bn(modulusBytes.bytes, (int)modulusBytes.length, NULL);
    BIGNUM *generator = BN_bin2bn(generatorBytes.bytes, (int)generatorBytes.length, NULL);
    BIGNUM *serverPublic = BN_bin2bn(serverPublicBytes.bytes, (int)serverPublicBytes.length, NULL);
    BIGNUM *clientPrivate = BN_secure_new();
    BIGNUM *clientPublic = BN_new();
    BIGNUM *passwordExponent = BN_secure_new();
    BIGNUM *multiplier = BN_new();
    BIGNUM *scrambler = BN_new();
    BIGNUM *passwordVerifier = BN_new();
    BIGNUM *sharedSecretBase = BN_new();
    BIGNUM *sharedSecretExponent = BN_secure_new();
    BIGNUM *sharedSecret = BN_secure_new();
    BN_CTX *bigNumberContext = BN_CTX_secure_new();
    NSMutableData *stretchedPassword = [NSMutableData dataWithLength:128];
    NSData *sessionKey = nil, *clientProof = nil, *expectedServerProof = nil, *clientPublicBytes = nil;
    BOOL ok = group && modulus && generator && serverPublic && clientPrivate && clientPublic && passwordExponent &&
              multiplier && scrambler && passwordVerifier && sharedSecretBase && sharedSecretExponent && sharedSecret &&
              bigNumberContext && BN_cmp(modulus, group->N) == 0 && BN_cmp(generator, group->g) == 0 &&
              modulusBytes.length == 512 && serverPublicBytes.length <= 512 && !BN_is_zero(serverPublic) &&
              BN_cmp(serverPublic, modulus) < 0;
    if (ok) {
        [self fail:FCVNCAppleSessionAuthenticationError
            message:@"Apple authentication could not compute its SRP proof."];
        BN_set_flags(clientPrivate, BN_FLG_CONSTTIME);
        BN_set_flags(passwordExponent, BN_FLG_CONSTTIME);
        BN_set_flags(sharedSecretExponent, BN_FLG_CONSTTIME);
        ok = PKCS5_PBKDF2_HMAC(passwordBytes.bytes, (int)passwordBytes.length, salt.bytes, (int)salt.length,
                               (int)iterations, EVP_sha512(), 128, stretchedPassword.mutableBytes) == 1 &&
             BN_priv_rand(clientPrivate, 256, BN_RAND_TOP_ONE, BN_RAND_BOTTOM_ANY) == 1 &&
             BN_mod_exp_mont_consttime(clientPublic, generator, clientPrivate, modulus, bigNumberContext, NULL) == 1;
    }
    if (ok) {
        NSData *passwordHash = Digest(EVP_sha512(), @[ [NSData dataWithBytes:":" length:1], stretchedPassword ]);
        NSData *passwordExponentHash = passwordHash ? Digest(EVP_sha512(), @[ salt, passwordHash ]) : nil;
        NSData *multiplierHash =
            Digest(EVP_sha512(), @[ PaddedBigNumberData(modulus, 512), PaddedBigNumberData(generator, 512) ]);
        clientPublicBytes = PaddedBigNumberData(clientPublic, 512);
        NSData *scramblerHash =
            clientPublicBytes ? Digest(EVP_sha512(), @[ clientPublicBytes, PaddedBigNumberData(serverPublic, 512) ])
                              : nil;
        // x, k and u are hashes interpreted as big-endian integers.
        ok = passwordExponentHash && multiplierHash && scramblerHash &&
             BN_bin2bn(passwordExponentHash.bytes, (int)passwordExponentHash.length, passwordExponent) &&
             BN_bin2bn(multiplierHash.bytes, (int)multiplierHash.length, multiplier) &&
             BN_bin2bn(scramblerHash.bytes, (int)scramblerHash.length, scrambler) && !BN_is_zero(scrambler);
        if (ok) {
            // Base = B - k * g^x (mod N).
            ok = BN_mod_exp_mont_consttime(passwordVerifier, generator, passwordExponent, modulus, bigNumberContext,
                                           NULL) &&
                 BN_mod_mul(sharedSecretBase, multiplier, passwordVerifier, modulus, bigNumberContext) &&
                 BN_mod_sub(sharedSecretBase, serverPublic, sharedSecretBase, modulus, bigNumberContext);
        }
        if (ok) {
            // Exponent = a + u*x; S = base^exponent (mod N).
            ok = BN_mul(sharedSecretExponent, scrambler, passwordExponent, bigNumberContext) &&
                 BN_add(sharedSecretExponent, sharedSecretExponent, clientPrivate) &&
                 BN_mod_exp_mont_consttime(sharedSecret, sharedSecretBase, sharedSecretExponent, modulus,
                                           bigNumberContext, NULL);
        }
        if (ok) {
            sessionKey = Digest(EVP_sha512(), @[ PaddedBigNumberData(sharedSecret, 512) ]);
            NSData *modulusHash = Digest(EVP_sha512(), @[ modulusBytes ]),
                   *generatorHash = Digest(EVP_sha512(), @[ PaddedBigNumberData(generator, 512) ]),
                   *identityHash = Digest(EVP_sha512(), @[ [NSData data] ]);
            NSMutableData *groupHashXOR = [modulusHash mutableCopy];
            for (NSUInteger i = 0; i < groupHashXOR.length; i++)
                ((unsigned char *)groupHashXOR.mutableBytes)[i] ^= ((const unsigned char *)generatorHash.bytes)[i];
            clientProof = Digest(EVP_sha512(), @[
                groupHashXOR, identityHash, salt, clientPublicBytes, PaddedBigNumberData(serverPublic, 512), sessionKey
            ]);
            expectedServerProof = Digest(EVP_sha512(), @[ clientPublicBytes, clientProof, sessionKey ]);
            NSData *wrappingKeyHash = Digest(EVP_sha256(), @[ sessionKey ]);
            if (wrappingKeyHash.length == 32) {
                memcpy(_wrapKey, wrappingKeyHash.bytes, 16);
            } else
                ok = NO;
        }
    }
    OPENSSL_cleanse(stretchedPassword.mutableBytes, stretchedPassword.length);
    BN_clear_free(modulus);
    BN_clear_free(generator);
    BN_clear_free(serverPublic);
    BN_clear_free(clientPrivate);
    BN_clear_free(clientPublic);
    BN_clear_free(passwordExponent);
    BN_clear_free(multiplier);
    BN_clear_free(scrambler);
    BN_clear_free(passwordVerifier);
    BN_clear_free(sharedSecretBase);
    BN_clear_free(sharedSecretExponent);
    BN_clear_free(sharedSecret);
    BN_CTX_free(bigNumberContext);
    if (!ok || self.isCancelled())
        return nil;
    FCVNCAppleSRPProofs *proofs = [FCVNCAppleSRPProofs new];
    proofs.clientPublicBytes = clientPublicBytes;
    proofs.clientProof = clientProof;
    proofs.expectedServerProof = expectedServerProof;
    proofs.options = options;
    return proofs;
}
- (BOOL)authenticateUsername:(NSString *)username password:(NSString *)password {
    [self fail:FCVNCAppleSessionInputError
        message:@"Apple Screen Sharing requires a Mac account username and password."];
    NSData *usernameBytes = [username dataUsingEncoding:NSUTF8StringEncoding],
           *passwordBytes = [password dataUsingEncoding:NSUTF8StringEncoding];
    if (!usernameBytes.length || usernameBytes.length > 128 || passwordBytes.length > 4096)
        return NO;
    if (![self negotiateRSA])
        return NO;
    EVP_PKEY *key = [self approvedServerKey];
    if (!key)
        return NO;
    NSData *encrypted = [self encryptIdentity:usernameBytes key:key];
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
    FCVNCAppleSRPProofs *proofs = [self proofsForChallenge:challenge password:passwordBytes];
    if (!proofs)
        return NO;
    return [self exchangeProofs:proofs];
}
- (BOOL)exchangeProofs:(FCVNCAppleSRPProofs *)proofs {
    unsigned char clientNonce[16];
    if (RAND_bytes(clientNonce, sizeof(clientNonce)) != 1)
        return NO;
    NSMutableData *proof = [NSMutableData data];
    AppendLengthPrefixedData(proof, proofs.clientPublicBytes, NO);
    AppendLengthPrefixedData(proof, proofs.clientProof, YES);
    AppendLengthPrefixedData(proof, proofs.options, NO);
    AppendLengthPrefixedData(proof, [NSData dataWithBytes:clientNonce length:16], YES);
    NSMutableData *body = [NSMutableData data];
    AppendUInt16(body, 0);
    AppendUInt16(body, proof.length);
    [body appendData:proof];
    if (![self sendRSA:2 body:body length:body.length])
        return NO;
    NSData *serverResponse = [self authFrame];
    if (!serverResponse)
        return NO;
    NSUInteger responseOffset = 0;
    NSData *serverProof = ReadLengthPrefixedData(serverResponse, &responseOffset, YES);
    [self fail:FCVNCAppleSessionAuthenticationError message:@"Apple Screen Sharing authentication proof was rejected."];
    if (serverProof.length != proofs.expectedServerProof.length ||
        CRYPTO_memcmp(serverProof.bytes, proofs.expectedServerProof.bytes, proofs.expectedServerProof.length)) {
        _authenticationRejected = YES;
        return NO;
    }
    NSData *serverRandom = ReadLengthPrefixedData(serverResponse, &responseOffset, YES),
           *empty = ReadLengthPrefixedData(serverResponse, &responseOffset, NO),
           *reserved = ReadData(serverResponse, &responseOffset, 4);
    if (serverRandom.length != 16 || !empty || !reserved || responseOffset != serverResponse.length)
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
    EVP_CIPHER_CTX *keyUnwrapCipher = EVP_CIPHER_CTX_new();
    unsigned char sessionKeyAndIV[32];
    int decryptedLength = 0;
    BOOL ok = keyUnwrapCipher && EVP_DecryptInit_ex(keyUnwrapCipher, EVP_aes_128_ecb(), NULL, _wrapKey, NULL) == 1 &&
              EVP_CIPHER_CTX_set_padding(keyUnwrapCipher, 0) == 1 &&
              EVP_DecryptUpdate(keyUnwrapCipher, sessionKeyAndIV, &decryptedLength,
                                (const unsigned char *)payload.bytes + 4, 32) == 1 &&
              decryptedLength == 32;
    EVP_CIPHER_CTX_free(keyUnwrapCipher);
    if (ok) {
        if (!_sendCipher)
            _sendCipher = EVP_CIPHER_CTX_new();
        if (!_receiveCipher)
            _receiveCipher = EVP_CIPHER_CTX_new();
        if (!_inputCipher)
            _inputCipher = EVP_CIPHER_CTX_new();
        ok = _sendCipher && _receiveCipher && _inputCipher &&
             EVP_EncryptInit_ex(_inputCipher, EVP_aes_128_ecb(), NULL, sessionKeyAndIV, NULL) == 1 &&
             EVP_CIPHER_CTX_set_padding(_inputCipher, 0) == 1 &&
             EVP_EncryptInit_ex(_sendCipher, EVP_aes_128_cbc(), NULL, sessionKeyAndIV, sessionKeyAndIV + 16) == 1 &&
             EVP_DecryptInit_ex(_receiveCipher, EVP_aes_128_cbc(), NULL, sessionKeyAndIV, sessionKeyAndIV + 16) == 1 &&
             EVP_CIPHER_CTX_set_padding(_sendCipher, 0) == 1 && EVP_CIPHER_CTX_set_padding(_receiveCipher, 0) == 1;
        if (ok) {
            memcpy(_wrapKey, sessionKeyAndIV, 16);
            _encrypted = YES;
        }
    }
    OPENSSL_cleanse(sessionKeyAndIV, sizeof(sessionKeyAndIV));
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
- (BOOL)writeInputBytes:(const unsigned char *)eventBytes count:(NSUInteger)count {
    BOOL keyboard = count == 8 && eventBytes[0] == 4;
    BOOL pointer = count == 6 && eventBytes[0] == 5;
    if (!_authenticated || !_encrypted || (!keyboard && !pointer))
        return NO;
    // Apple mandates ECB here, CBC/SHA-1 records and RSA PKCS#1 v1.5 at
    // authentication. These are wire requirements, not general crypto choices.
    // All writes/rekeys run on the owning VNC worker.
    // Apple input has a separate ECB envelope inside the authenticated record.
    // The event cipher follows the current session key after every rekey.
    unsigned char plaintextEvent[16] = {0}, packet[18] = {0x10, pointer ? 1 : 0};
    if (keyboard) {
        plaintextEvent[0] = 0xff;
        plaintextEvent[1] = eventBytes[1];
        memcpy(plaintextEvent + 2, eventBytes + 4, 4);
    } else {
        plaintextEvent[10] = 0xff;
        plaintextEvent[11] = eventBytes[1];
        memcpy(plaintextEvent + 12, eventBytes + 2, 4);
    }
    int encryptedLength = 0;
    BOOL ok =
        _inputCipher &&
        EVP_EncryptUpdate(_inputCipher, packet + 2, &encryptedLength, plaintextEvent, sizeof(plaintextEvent)) == 1 &&
        encryptedLength == sizeof(plaintextEvent);
    OPENSSL_cleanse(plaintextEvent, sizeof(plaintextEvent));
    return ok && [self write:packet count:sizeof(packet)];
}
- (BOOL)read:(void *)bytes count:(NSUInteger)count {
    if (!_encrypted)
        return self.readTransport(bytes, count);
    NSUInteger bytesRead = 0;
    while (bytesRead < count && !self.isCancelled()) {
        if (_receivePayloadOffset == _receivePayload.length) {
            if (_receiveSequence > UINT32_MAX)
                return NO;
            NSData *prefix = [self transportData:2];
            if (!prefix)
                return NO;
            NSUInteger recordLength = FCVNCRead16(prefix.bytes);
            if (recordLength < 32 || recordLength % 16)
                return NO;
            NSData *ciphertext = [self transportData:recordLength];
            if (!ciphertext)
                return NO;
            NSMutableData *plaintext = [NSMutableData dataWithLength:recordLength];
            int written = 0;
            if (EVP_DecryptUpdate(_receiveCipher, plaintext.mutableBytes, &written, ciphertext.bytes,
                                  (int)recordLength) != 1 ||
                written != recordLength)
                return NO;
            unsigned char sequenceBytes[4];
            FCVNCWrite32(sequenceBytes, (uint32_t)_receiveSequence);
            NSData *expectedDigest = Digest(EVP_sha1(), @[
                [NSData dataWithBytes:sequenceBytes length:4],
                [plaintext subdataWithRange:NSMakeRange(0, recordLength - 20)]
            ]);
            NSUInteger payloadLength = FCVNCRead16(plaintext.bytes);
            if (!payloadLength || payloadLength > recordLength - 22 || recordLength - payloadLength - 22 > 15 ||
                expectedDigest.length != 20 ||
                CRYPTO_memcmp(expectedDigest.bytes, (const unsigned char *)plaintext.bytes + recordLength - 20, 20)) {
                OPENSSL_cleanse(plaintext.mutableBytes, plaintext.length);
                return NO;
            }
            _receivePayload = [plaintext subdataWithRange:NSMakeRange(2, payloadLength)];
            _receivePayloadOffset = 0;
            _receiveSequence++;
            OPENSSL_cleanse(plaintext.mutableBytes, plaintext.length);
        }
        NSUInteger chunkLength = MIN(count - bytesRead, _receivePayload.length - _receivePayloadOffset);
        memcpy((unsigned char *)bytes + bytesRead, (const unsigned char *)_receivePayload.bytes + _receivePayloadOffset,
               chunkLength);
        _receivePayloadOffset += chunkLength;
        bytesRead += chunkLength;
    }
    return bytesRead == count;
}
+ (NSData *)displayWidth:(NSUInteger)width height:(NSUInteger)height retina:(BOOL)retina {
    NSUInteger scale = retina ? 2 : 1;
    if (width < 200 || height < 200 || width > 3840 / scale || height > 2160 / scale)
        return nil;
    NSMutableData *configuration =
        [NSMutableData dataWithLength:FCVNCDisplayHeaderSize + FCVNCDisplayInfoSize + FCVNCDisplayModeSize];
    unsigned char *configurationBytes = configuration.mutableBytes;
    configurationBytes[0] = 0x1d;
    FCVNCWrite16(configurationBytes + 2, configuration.length - 4);
    FCVNCWrite16(configurationBytes + 4, 1);
    FCVNCWrite16(configurationBytes + 6, 1);
    unsigned char *display = configurationBytes + FCVNCDisplayHeaderSize;
    FCVNCWrite16(display, FCVNCDisplayInfoSize + FCVNCDisplayModeSize);
    memcpy(display + 2, FCVNC_DISPLAY_NAME, sizeof(FCVNC_DISPLAY_NAME));
    FCVNCWrite32(display + FCVNCDisplayFlags, 1);
    FCVNCWrite32(display + FCVNCDisplayDepth, 4);
    float physicalWidthMillimeters = (float)width * 25.4f / 132,
          physicalHeightMillimeters = (float)height * 25.4f / 132;
    uint32_t physicalWidthBits, physicalHeightBits;
    memcpy(&physicalWidthBits, &physicalWidthMillimeters, 4);
    memcpy(&physicalHeightBits, &physicalHeightMillimeters, 4);
    FCVNCWrite32(display + FCVNCDisplayPhysicalWidth, physicalWidthBits);
    FCVNCWrite32(display + FCVNCDisplayPhysicalHeight, physicalHeightBits);
    FCVNCWrite32(display + FCVNCDisplayMaxWidth, 3840);
    FCVNCWrite32(display + FCVNCDisplayMaxHeight, 2160);
    FCVNCWrite16(display + FCVNCDisplayModeCount, 1);
    unsigned char *mode = display + FCVNCDisplayInfoSize;
    FCVNCWrite32(mode, (uint32_t)(width * scale));
    FCVNCWrite32(mode + 4, (uint32_t)(height * scale));
    FCVNCWrite32(mode + 8, (uint32_t)width);
    FCVNCWrite32(mode + 12, (uint32_t)height);
    double refreshRateHertz = 60;
    uint64_t refreshRateBits;
    memcpy(&refreshRateBits, &refreshRateHertz, 8);
    for (int i = 0; i < 8; i++)
        mode[16 + i] = refreshRateBits >> (56 - i * 8);
    return configuration;
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
    NSData *usernameBytes = [username dataUsingEncoding:NSUTF8StringEncoding],
           *passwordBytes = [password dataUsingEncoding:NSUTF8StringEncoding];
    [self fail:FCVNCAppleSessionDesktopError
        message:@"Apple automatic desktop login requires a username and password of at most 63 UTF-8 bytes each, "
                @"without embedded NUL characters."];
    if (!usernameBytes.length || usernameBytes.length >= 64 || passwordBytes.length >= 64 ||
        memchr(usernameBytes.bytes, 0, usernameBytes.length) ||
        (passwordBytes.length && memchr(passwordBytes.bytes, 0, passwordBytes.length)))
        return NO;
    // RFBSelectSession v2, command 2. Each fixed-size credential field is
    // encrypted with the SRP-derived AES key, after mutual proof verification.
    // This is protocol login, never keyboard input into an unidentified screen.
    unsigned char packet[FCVNCDesktopLoginSize] = {0}, credentialBytes[128];
    FCVNCWrite16(packet, 200);
    FCVNCWrite16(packet + 2, 2);
    packet[8] = 2;
    memcpy(packet + 10, FCVNC_APP_NAME, sizeof(FCVNC_APP_NAME));
    BOOL ok = RAND_bytes(credentialBytes, sizeof(credentialBytes)) == 1;
    if (ok) {
        memcpy(credentialBytes, usernameBytes.bytes, usernameBytes.length);
        credentialBytes[usernameBytes.length] = 0;
        memcpy(credentialBytes + 64, passwordBytes.bytes, passwordBytes.length);
        credentialBytes[64 + passwordBytes.length] = 0;
        EVP_CIPHER_CTX *cipher = EVP_CIPHER_CTX_new();
        int count = 0;
        ok = cipher && EVP_EncryptInit_ex(cipher, EVP_aes_128_ecb(), NULL, _wrapKey, NULL) == 1 &&
             EVP_CIPHER_CTX_set_padding(cipher, 0) == 1 &&
             EVP_EncryptUpdate(cipher, packet + FCVNCDesktopLoginCredentials, &count, credentialBytes,
                               sizeof(credentialBytes)) == 1 &&
             count == sizeof(credentialBytes);
        EVP_CIPHER_CTX_free(cipher);
    }
    OPENSSL_cleanse(credentialBytes, sizeof(credentialBytes));
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
    const unsigned char *replyBytes = reply.bytes;
    // Prefix was consumed separately: version and status are offsets 0 and 2.
    if (FCVNCRead16(replyBytes) != 1)
        return NO;
    if (replyBytes[2] != 2) {
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
    NSOperatingSystemVersion systemVersion = NSProcessInfo.processInfo.operatingSystemVersion;
    FCVNCWrite32(viewer + 22, (uint32_t)systemVersion.majorVersion);
    FCVNCWrite32(viewer + 26, (uint32_t)systemVersion.minorVersion);
    FCVNCWrite32(viewer + 30, (uint32_t)systemVersion.patchVersion);
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
    const unsigned char *updateBytes = update.bytes;
    if (updateBytes[0] != 0 || FCVNCRead16(updateBytes + 2) != 1 || FCVNCRead32(updateBytes + 12) != 0x44f)
        return NO;
    NSData *payload = [self transportData:36];
    if (![self rekey:payload])
        return NO;
    NSData *configuration = [FCVNCAppleSession displayWidth:width height:height retina:retina];
    return configuration && [self write:configuration.bytes count:configuration.length];
}
@end
