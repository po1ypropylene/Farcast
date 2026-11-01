#import "VNCAppleMediaOffer.h"
#import "VNCAppleWire.h"
#import <Security/Security.h>
#import <zlib.h>

// Generated AVConference bandwidth settings call field 3 configurationExtension:
// these are mode bitmasks, not startup/minimum rates. Both Wi-Fi and wired modes
// are required; retain their ceilings pending user-side throughput comparisons.
enum { FCVNCLowLatencyWiFiModes = 98304, FCVNCLowLatencyWiredMode = 262144 };
static void AppendVarint(NSMutableData *out, uint64_t value) {
    do {
        uint8_t encodedByte = (value & 127) | (value > 127 ? 128 : 0);
        [out appendBytes:&encodedByte length:1];
        value >>= 7;
    } while (value);
}
static void AppendNumberField(NSMutableData *out, unsigned field, uint64_t value) {
    AppendVarint(out, field << 3);
    AppendVarint(out, value);
}
static void AppendBytesField(NSMutableData *out, unsigned field, NSData *data) {
    AppendVarint(out, (field << 3) | 2);
    AppendVarint(out, data.length);
    [out appendData:data];
}
static void AppendTextField(NSMutableData *out, unsigned field, NSString *text) {
    AppendBytesField(out, field, [text dataUsingEncoding:NSUTF8StringEncoding]);
}
static NSData *Envelope(unsigned mode, unsigned field, NSData *settings, NSString *callID) {
    NSMutableData *blob = [NSMutableData data], *bandwidth = [NSMutableData data];
    AppendNumberField(blob, 1, 1);
    AppendNumberField(blob, 2, 1);
    AppendBytesField(blob, field, settings);
    AppendTextField(blob, 6, @FCVNC_APP_NAME);
    AppendNumberField(bandwidth, 1, 0);
    AppendNumberField(bandwidth, 2, 20000000);
    AppendNumberField(bandwidth, 3, FCVNCLowLatencyWiFiModes);
    AppendBytesField(blob, 9, bandwidth);
    // Both low-latency profiles are required. Omitting Wired makes Apple's
    // generated transmitter configuration select a maximum bitrate of zero.
    bandwidth = [NSMutableData data];
    AppendNumberField(bandwidth, 1, 0);
    AppendNumberField(bandwidth, 2, 60000000);
    AppendNumberField(bandwidth, 3, FCVNCLowLatencyWiredMode);
    AppendBytesField(blob, 9, bandwidth);
    AppendNumberField(blob, 14, 2);
    uLongf length = compressBound(blob.length);
    NSMutableData *compressed = [NSMutableData dataWithLength:length];
    if (compress2(compressed.mutableBytes, &length, blob.bytes, blob.length, Z_DEFAULT_COMPRESSION) != Z_OK)
        return nil;
    compressed.length = length;
    NSMutableData *endpoint = [NSMutableData data];
    AppendNumberField(endpoint, 1, 0);
    AppendNumberField(endpoint, 2, 1);
    AppendTextField(endpoint, 3, @FCVNC_APP_NAME);
    AppendTextField(endpoint, 4,
                    [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1");
    AppendTextField(
        endpoint, 5,
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
static BOOL ReadVarint(const uint8_t *bytes, NSUInteger length, NSUInteger *offset, uint64_t *value) {
    *value = 0;
    for (unsigned shift = 0; shift < 70 && *offset < length; shift += 7) {
        uint8_t encodedByte = bytes[(*offset)++];
        if (shift == 63 && encodedByte > 1)
            return NO;
        *value |= (uint64_t)(encodedByte & 127) << shift;
        if (!(encodedByte & 128))
            return YES;
    }
    return NO;
}
static NSDictionary<NSNumber *, NSArray *> *ParseFields(NSData *data) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0, count = 0;
    while (offset < data.length) {
        uint64_t tag, valueOrLength;
        if (++count > 256 || !ReadVarint(bytes, data.length, &offset, &tag) || !(tag >> 3) || tag >> 3 > 0x1fffffff)
            return nil;
        unsigned wireType = tag & 7;
        if (wireType != 0 && wireType != 2)
            return nil;
        if (!ReadVarint(bytes, data.length, &offset, &valueOrLength))
            return nil;
        id value;
        if (wireType == 0)
            value = @(valueOrLength);
        else {
            if (valueOrLength > data.length - offset)
                return nil;
            value = [data subdataWithRange:NSMakeRange(offset, (NSUInteger)valueOrLength)];
            offset += valueOrLength;
        }
        NSNumber *field = @(tag >> 3);
        if (!result[field])
            result[field] = [NSMutableArray array];
        [result[field] addObject:value];
    }
    return result;
}
static id SingleField(NSDictionary *fields, unsigned field, Class type) {
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
    AppendNumberField(rule, 1, 1); // Wi-Fi/IP transport.
    AppendNumberField(rule, 2, 2); // Receive/decode only.
    AppendNumberField(rule, 3, 50115);
    AppendNumberField(rule, 4, 0);
    AppendNumberField(payload, 1, 100); // HEVC payload type.
    AppendBytesField(payload, 2, rule);
    AppendTextField(payload, 3, @"FLS;LF:-1;LTR;POS:5;EOD:1;HTS:2;RR:3;POSE:4;SW:0;AR:8/5,5/8;XR:8/5,5/8;");
    AppendNumberField(payload, 4, 14);
    AppendNumberField(screen, 1, _receiverSSRC);
    AppendNumberField(screen, 2, 1);
    AppendBytesField(screen, 3, payload);
    AppendNumberField(screen, 4, width);
    AppendNumberField(screen, 5, height);
    AppendNumberField(screen, 6, 1); // One tile, one decoder.
    AppendNumberField(screen, 7, 1); // Acknowledge only successfully hardware-decoded reference identifiers.
    AppendNumberField(screen, 8, 1); // Full-range 8-bit 4:2:0.
    AppendNumberField(screen, 9, 1); // SDR.
    AppendNumberField(screen, 12, 0);
    _video = Envelope(7, 5, screen, _callID.UUIDString);
    NSMutableData *audio = [NSMutableData data];
    AppendNumberField(audio, 1, _receiverSSRC ^ 0x80000000);
    AppendNumberField(audio, 2, 0);
    AppendNumberField(audio, 3, 0);
    AppendNumberField(audio, 4, 1); // Mandatory audio negotiation, below the audio bitrate floor.
    AppendNumberField(audio, 5, 0);
    AppendNumberField(audio, 6, 0);
    _audio = Envelope(8, 3, audio, _callID.UUIDString);
    return _video && _audio ? self : nil;
}
- (NSData *)configurationWithSendKey:(NSData *)sendKey receiveKey:(NSData *)receiveKey {
    if (sendKey.length != 46 || receiveKey.length != 46 || _audio.length > 16000 || _video.length > 16000)
        return nil;
    NSMutableData *packet = [NSMutableData dataWithLength:FCVNCMediaFixedSize + _audio.length + _video.length];
    uint8_t *bytes = packet.mutableBytes;
    bytes[0] = 0x1c;
    FCVNCWrite16(bytes + 2, packet.length - 4);
    FCVNCWrite16(bytes + 4, 3);
    bytes[6] = 1; // One 60 Hz stream, with the server cursor included in the video.
    FCVNCWrite16(bytes + 10, _audio.length);
    FCVNCWrite16(bytes + 12, _video.length);
    uuid_t uuid;
    [_callID getUUIDBytes:uuid];
    memcpy(bytes + 20, uuid, 16);
    // Audio is disabled, but its mandatory key slots must still be unpredictable.
    if (SecRandomCopyBytes(kSecRandomDefault, 2 * FCVNCMediaKeySize, bytes + FCVNCMediaHeaderSize) != errSecSuccess)
        return nil;
    memcpy(bytes + FCVNCMediaAudioOffset, _audio.bytes, _audio.length);
    NSUInteger offset = FCVNCMediaAudioOffset + _audio.length;
    memcpy(bytes + offset, sendKey.bytes, FCVNCMediaKeySize);
    memcpy(bytes + offset + FCVNCMediaKeySize, receiveKey.bytes, FCVNCMediaKeySize);
    memcpy(bytes + offset + 2 * FCVNCMediaKeySize, _video.bytes, _video.length);
    return packet;
}
+ (BOOL)acceptVideoAnswer:(NSData *)answer senderSSRC:(uint32_t *)senderSSRC {
    BOOL decodingOrderNumbers;
    return [self acceptVideoAnswer:answer senderSSRC:senderSSRC decodingOrderNumbers:&decodingOrderNumbers];
}
+ (BOOL)acceptVideoAnswer:(NSData *)answer
               senderSSRC:(uint32_t *)senderSSRC
     decodingOrderNumbers:(BOOL *)decodingOrderNumbers {
    BOOL longTermReference, allowFeedback;
    return [self acceptVideoAnswer:answer
                        senderSSRC:senderSSRC
              decodingOrderNumbers:decodingOrderNumbers
                 longTermReference:&longTermReference
                     allowFeedback:&allowFeedback];
}
+ (BOOL)acceptVideoAnswer:(NSData *)answer
               senderSSRC:(uint32_t *)senderSSRC
     decodingOrderNumbers:(BOOL *)decodingOrderNumbers
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
    NSMutableData *decompressedSettings = [NSMutableData dataWithLength:65536];
    uLongf length = decompressedSettings.length;
    if (uncompress(decompressedSettings.mutableBytes, &length, compressed.bytes, compressed.length) != Z_OK)
        return NO;
    decompressedSettings.length = length;
    NSDictionary *root = ParseFields(decompressedSettings);
    NSData *settings = SingleField(root, 5, NSData.class);
    if (!settings)
        return NO;
    NSDictionary *screen = ParseFields(settings);
    NSNumber *sender = SingleField(screen, 1, NSNumber.class), *pixelFormat = SingleField(screen, 8, NSNumber.class);
    if (!sender || !sender.unsignedIntValue || sender.unsignedLongLongValue > UINT32_MAX ||
        pixelFormat.unsignedIntValue != 1)
        return NO;
    // Omitted fields have protobuf defaults: one tile and no LTR.
    if (screen[@6] && [SingleField(screen, 6, NSNumber.class) unsignedIntValue] != 1)
        return NO;
    NSNumber *feedback = SingleField(screen, 2, NSNumber.class);
    if (screen[@2] && (!feedback || feedback.unsignedLongLongValue > 1))
        return NO;
    NSNumber *referenceAcknowledgements = SingleField(screen, 7, NSNumber.class);
    if (screen[@7] && (!referenceAcknowledgements || referenceAcknowledgements.unsignedLongLongValue > 1))
        return NO;
    if ([SingleField(screen, 9, NSNumber.class) unsignedLongLongValue] != 1)
        return NO;
    NSArray *payloads = screen[@3];
    if (payloads.count != 1 || ![payloads[0] isKindOfClass:NSData.class])
        return NO;
    NSDictionary *payload = ParseFields(payloads[0]);
    if ([SingleField(payload, 1, NSNumber.class) unsignedIntValue] != 100)
        return NO;
    NSNumber *interleaving = SingleField(screen, 14, NSNumber.class);
    if (screen[@14] && (!interleaving || interleaving.unsignedLongLongValue > 1))
        return NO;
    *decodingOrderNumbers = interleaving.boolValue;
    *longTermReference = referenceAcknowledgements.boolValue;
    *allowFeedback = feedback.boolValue;
    *senderSSRC = sender.unsignedIntValue;
    return YES;
}
@end
