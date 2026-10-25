#import "VNCAppleMediaOffer.h"
#import "VNCAppleWire.h"
#import <Security/Security.h>
#import <zlib.h>

// Generated AVConference bandwidth settings call field 3 configurationExtension:
// these are mode bitmasks, not startup/minimum rates. Both Wi-Fi and wired modes
// are required; retain their ceilings pending user-side throughput comparisons.
enum { FCVNCLowLatencyWiFiModes = 98304, FCVNCLowLatencyWiredMode = 262144 };
static void Varint(NSMutableData *out, uint64_t n) {
    do {
        uint8_t b = (n & 127) | (n > 127 ? 128 : 0);
        [out appendBytes:&b length:1];
        n >>= 7;
    } while (n);
}
static void Number(NSMutableData *out, unsigned field, uint64_t n) {
    Varint(out, field << 3);
    Varint(out, n);
}
static void Bytes(NSMutableData *out, unsigned field, NSData *data) {
    Varint(out, (field << 3) | 2);
    Varint(out, data.length);
    [out appendData:data];
}
static void Text(NSMutableData *out, unsigned field, NSString *text) {
    Bytes(out, field, [text dataUsingEncoding:NSUTF8StringEncoding]);
}
static NSData *Envelope(unsigned mode, unsigned field, NSData *settings, NSString *callID) {
    NSMutableData *blob = [NSMutableData data], *bandwidth = [NSMutableData data];
    Number(blob, 1, 1);
    Number(blob, 2, 1);
    Bytes(blob, field, settings);
    Text(blob, 6, @FCVNC_APP_NAME);
    Number(bandwidth, 1, 0);
    Number(bandwidth, 2, 20000000);
    Number(bandwidth, 3, FCVNCLowLatencyWiFiModes);
    Bytes(blob, 9, bandwidth);
    // Both low-latency profiles are required. Omitting Wired makes Apple's
    // generated transmitter configuration select a maximum bitrate of zero.
    bandwidth = [NSMutableData data];
    Number(bandwidth, 1, 0);
    Number(bandwidth, 2, 60000000);
    Number(bandwidth, 3, FCVNCLowLatencyWiredMode);
    Bytes(blob, 9, bandwidth);
    Number(blob, 14, 2);
    uLongf length = compressBound(blob.length);
    NSMutableData *compressed = [NSMutableData dataWithLength:length];
    if (compress2(compressed.mutableBytes, &length, blob.bytes, blob.length, Z_DEFAULT_COMPRESSION) != Z_OK)
        return nil;
    compressed.length = length;
    NSMutableData *endpoint = [NSMutableData data];
    Number(endpoint, 1, 0);
    Number(endpoint, 2, 1);
    Text(endpoint, 3, @FCVNC_APP_NAME);
    Text(endpoint, 4, [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1");
    Text(endpoint, 5,
         [NSString stringWithFormat:@"%ld", (long)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion]);
    return [NSPropertyListSerialization dataWithPropertyList:@{
        @"avcMediaStreamNegotiatorMode" : @(mode),
        @"avcMediaStreamOptionCallID" : callID,
        @"avcMediaStreamOptionRemoteEndpointInfo" : endpoint,
        @"avcMediaStreamNegotiatorMediaBlob" : compressed
    }
                                                      format:NSPropertyListBinaryFormat_v1_0
                                                     options:0
                                                       error:nil];
}
// Limited protobuf reader: preserves repeated fields, refuses malformed lengths,
// overflowing varints, groups and unsupported fixed-width values.
static BOOL ReadVarint(const uint8_t *p, NSUInteger length, NSUInteger *offset, uint64_t *value) {
    *value = 0;
    for (unsigned shift = 0; shift < 70 && *offset < length; shift += 7) {
        uint8_t b = p[(*offset)++];
        if (shift == 63 && b > 1)
            return NO;
        *value |= (uint64_t)(b & 127) << shift;
        if (!(b & 128))
            return YES;
    }
    return NO;
}
static NSDictionary<NSNumber *, NSArray *> *Fields(NSData *data) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    const uint8_t *p = data.bytes;
    NSUInteger offset = 0, count = 0;
    while (offset < data.length) {
        uint64_t tag, n;
        if (++count > 256 || !ReadVarint(p, data.length, &offset, &tag) || !(tag >> 3) || tag >> 3 > 0x1fffffff)
            return nil;
        unsigned wire = tag & 7;
        if (wire != 0 && wire != 2)
            return nil;
        if (!ReadVarint(p, data.length, &offset, &n))
            return nil;
        id value;
        if (wire == 0)
            value = @(n);
        else {
            if (n > data.length - offset)
                return nil;
            value = [data subdataWithRange:NSMakeRange(offset, (NSUInteger)n)];
            offset += n;
        }
        NSNumber *field = @(tag >> 3);
        if (!result[field])
            result[field] = [NSMutableArray array];
        [result[field] addObject:value];
    }
    return result;
}
static id Single(NSDictionary *fields, unsigned field, Class type) {
    NSArray *values = fields[@(field)];
    return values.count == 1 && [values[0] isKindOfClass:type] ? values[0] : nil;
}
@implementation FCVNCAppleMediaOffer {
    NSUUID *_callID;
}
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height {
    if (!(self = [super init]))
        return nil;
    if (!width || !height || width > 3840 || height > 2160)
        return nil;
    _callID = [NSUUID UUID];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(_receiverSSRC), (uint8_t *)&_receiverSSRC) != errSecSuccess)
        return nil;
    if (!_receiverSSRC)
        _receiverSSRC = 1;
    NSMutableData *rule = [NSMutableData data], *payload = [NSMutableData data], *screen = [NSMutableData data];
    Number(rule, 1, 1); // Wi-Fi/IP transport.
    Number(rule, 2, 2); // Receive/decode only.
    Number(rule, 3, 50115);
    Number(rule, 4, 0);
    Number(payload, 1, 100); // HEVC payload type.
    Bytes(payload, 2, rule);
    Text(payload, 3, @"FLS;LF:-1;LTR;POS:5;EOD:1;HTS:2;RR:3;POSE:4;SW:0;AR:8/5,5/8;XR:8/5,5/8;");
    Number(payload, 4, 14);
    Number(screen, 1, _receiverSSRC);
    Number(screen, 2, 1);
    Bytes(screen, 3, payload);
    Number(screen, 4, width);
    Number(screen, 5, height);
    Number(screen, 6, 1); // One tile, one decoder.
    Number(screen, 7, 1); // Acknowledge only successfully hardware-decoded reference identifiers.
    Number(screen, 8, 1); // Full-range 8-bit 4:2:0.
    Number(screen, 9, 1); // SDR.
    Number(screen, 12, 0);
    _video = Envelope(7, 5, screen, _callID.UUIDString);
    NSMutableData *audio = [NSMutableData data];
    Number(audio, 1, _receiverSSRC ^ 0x80000000);
    Number(audio, 2, 0);
    Number(audio, 3, 0);
    Number(audio, 4, 1); // Mandatory audio negotiation, below the audio bitrate floor.
    Number(audio, 5, 0);
    Number(audio, 6, 0);
    _audio = Envelope(8, 3, audio, _callID.UUIDString);
    return _video && _audio ? self : nil;
}
- (NSData *)configurationWithSendKey:(NSData *)sendKey receiveKey:(NSData *)receiveKey {
    if (sendKey.length != 46 || receiveKey.length != 46 || _audio.length > 16000 || _video.length > 16000)
        return nil;
    NSMutableData *packet = [NSMutableData dataWithLength:FCVNCMediaFixedSize + _audio.length + _video.length];
    uint8_t *p = packet.mutableBytes;
    p[0] = 0x1c;
    FCVNCWrite16(p + 2, packet.length - 4);
    FCVNCWrite16(p + 4, 3);
    p[6] = 5; // One 60 Hz stream; omit the server cursor from the video.
    FCVNCWrite16(p + 10, _audio.length);
    FCVNCWrite16(p + 12, _video.length);
    uuid_t uuid;
    [_callID getUUIDBytes:uuid];
    memcpy(p + 20, uuid, 16);
    // Audio is disabled, but its mandatory key slots must still be unpredictable.
    if (SecRandomCopyBytes(kSecRandomDefault, 2 * FCVNCMediaKeySize, p + FCVNCMediaHeaderSize) != errSecSuccess)
        return nil;
    memcpy(p + FCVNCMediaAudioOffset, _audio.bytes, _audio.length);
    NSUInteger offset = FCVNCMediaAudioOffset + _audio.length;
    memcpy(p + offset, sendKey.bytes, FCVNCMediaKeySize);
    memcpy(p + offset + FCVNCMediaKeySize, receiveKey.bytes, FCVNCMediaKeySize);
    memcpy(p + offset + 2 * FCVNCMediaKeySize, _video.bytes, _video.length);
    return packet;
}
+ (BOOL)acceptVideoAnswer:(NSData *)answer senderSSRC:(uint32_t *)ssrc {
    BOOL enabled;
    return [self acceptVideoAnswer:answer senderSSRC:ssrc decodingOrderNumbers:&enabled];
}
+ (BOOL)acceptVideoAnswer:(NSData *)answer senderSSRC:(uint32_t *)ssrc decodingOrderNumbers:(BOOL *)enabled {
    BOOL longTermReference, allowFeedback;
    return [self acceptVideoAnswer:answer
                        senderSSRC:ssrc
              decodingOrderNumbers:enabled
                 longTermReference:&longTermReference
                     allowFeedback:&allowFeedback];
}
+ (BOOL)acceptVideoAnswer:(NSData *)answer
               senderSSRC:(uint32_t *)ssrc
     decodingOrderNumbers:(BOOL *)enabled
        longTermReference:(BOOL *)longTermReference
            allowFeedback:(BOOL *)allowFeedback {
    if (answer.length < 8 || answer.length > 32768 || memcmp(answer.bytes, "bplist00", 8))
        return NO;
    id wrapper = [NSPropertyListSerialization propertyListWithData:answer
                                                           options:NSPropertyListImmutable
                                                            format:nil
                                                             error:nil];
    if (![wrapper isKindOfClass:NSDictionary.class])
        return NO;
    NSData *compressed = wrapper[@"avcMediaStreamNegotiatorMediaBlob"];
    if (![compressed isKindOfClass:NSData.class] || compressed.length > 32768)
        return NO;
    NSMutableData *plain = [NSMutableData dataWithLength:65536];
    uLongf length = plain.length;
    if (uncompress(plain.mutableBytes, &length, compressed.bytes, compressed.length) != Z_OK)
        return NO;
    plain.length = length;
    NSDictionary *root = Fields(plain);
    NSData *settings = Single(root, 5, NSData.class);
    if (!settings)
        return NO;
    NSDictionary *screen = Fields(settings);
    NSNumber *sender = Single(screen, 1, NSNumber.class), *pixel = Single(screen, 8, NSNumber.class);
    if (!sender || !sender.unsignedIntValue || sender.unsignedLongLongValue > UINT32_MAX || pixel.unsignedIntValue != 1)
        return NO;
    // Omitted fields have protobuf defaults: one tile and no LTR.
    if (screen[@6] && [Single(screen, 6, NSNumber.class) unsignedIntValue] != 1)
        return NO;
    NSNumber *feedback = Single(screen, 2, NSNumber.class);
    if (screen[@2] && (!feedback || feedback.unsignedLongLongValue > 1))
        return NO;
    NSNumber *ltr = Single(screen, 7, NSNumber.class);
    if (screen[@7] && (!ltr || ltr.unsignedLongLongValue > 1))
        return NO;
    if ([Single(screen, 9, NSNumber.class) unsignedLongLongValue] != 1)
        return NO;
    NSArray *payloads = screen[@3];
    if (payloads.count != 1 || ![payloads[0] isKindOfClass:NSData.class])
        return NO;
    NSDictionary *payload = Fields(payloads[0]);
    if ([Single(payload, 1, NSNumber.class) unsignedIntValue] != 100)
        return NO;
    NSNumber *interleaving = Single(screen, 14, NSNumber.class);
    if (screen[@14] && (!interleaving || interleaving.unsignedLongLongValue > 1))
        return NO;
    *enabled = interleaving.boolValue;
    *longTermReference = ltr.boolValue;
    *allowFeedback = feedback.boolValue;
    *ssrc = sender.unsignedIntValue;
    return YES;
}
@end
