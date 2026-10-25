#import "VNCAppleFeedback.h"
#import "VNCAppleWire.h"
#import <math.h>
@implementation FCVNCAppleFeedback {
    uint32_t _receiver, _sender, _base, _highest, _received, _priorExpected, _priorReceived;
    int32_t _transit;
    double _jitter, _senderReportTime;
    uint32_t _senderReport;
    BOOL _sequenced;
}
- (instancetype)initWithReceiver:(uint32_t)receiver sender:(uint32_t)sender {
    if ((self = [super init])) {
        _receiver = receiver;
        _sender = sender;
    }
    return self;
}
- (void)receiveSequence:(uint16_t)sequence timestamp:(uint32_t)timestamp atTime:(double)now {
    int32_t transit = (int32_t)((uint32_t)fmod(now * 90000, 4294967296.0) - timestamp);
    if (!_sequenced) {
        _base = _highest = sequence;
        _sequenced = YES;
    } else {
        int16_t distance = (int16_t)(sequence - (uint16_t)_highest);
        if (distance > 0)
            _highest += distance;
        int64_t difference = (int32_t)((uint32_t)transit - (uint32_t)_transit);
        _jitter += ((double)llabs(difference) - _jitter) / 16;
    }
    _transit = transit;
    _received++;
}
- (void)receiveControl:(NSData *)packet atTime:(double)now {
    const uint8_t *p = packet.bytes;
    for (NSUInteger offset = 0; packet.length - offset >= 4;) {
        const uint8_t *part = p + offset;
        NSUInteger length = 4 * (1 + ((NSUInteger)part[2] << 8 | part[3]));
        if (part[0] >> 6 != 2 || length > packet.length - offset)
            return;
        if (part[1] == 200 && length >= 28 && FCVNCRead32(part + 4) == _sender) {
            _senderReport = FCVNCRead32(part + 8) << 16 | FCVNCRead32(part + 12) >> 16;
            _senderReportTime = now;
        }
        offset += length;
    }
}
- (NSMutableData *)reportAtTime:(double)now {
    NSUInteger reportSize = _sequenced ? 32 : 8;
    NSMutableData *data = [NSMutableData dataWithLength:reportSize + 20];
    uint8_t *p = data.mutableBytes;
    p[0] = _sequenced ? 0x81 : 0x80;
    p[1] = 201;
    p[3] = reportSize / 4 - 1;
    FCVNCWrite32(p + 4, _receiver);
    if (_sequenced) {
        uint32_t expected = _highest - _base + 1;
        int64_t lost = (int64_t)expected - _received;
        uint32_t interval = expected - _priorExpected;
        int64_t intervalLost = (int64_t)interval - (_received - _priorReceived);
        int32_t cumulative = (int32_t)MAX(-8388608, MIN(8388607, lost));
        FCVNCWrite32(p + 8, _sender);
        p[12] = interval && intervalLost > 0 ? (uint8_t)MIN(255, intervalLost * 256 / interval) : 0;
        p[13] = cumulative >> 16;
        p[14] = cumulative >> 8;
        p[15] = cumulative;
        FCVNCWrite32(p + 16, _highest);
        FCVNCWrite32(p + 20, (uint32_t)MIN(_jitter, UINT32_MAX));
        FCVNCWrite32(p + 24, _senderReport);
        FCVNCWrite32(p + 28,
                     _senderReportTime ? (uint32_t)MIN(MAX(0, now - _senderReportTime) * 65536, UINT32_MAX) : 0);
        _priorExpected = expected;
        _priorReceived = _received;
    }
    uint8_t *sdes = p + reportSize;
    sdes[0] = 0x81;
    sdes[1] = 202;
    sdes[3] = 4;
    FCVNCWrite32(sdes + 4, _receiver);
    sdes[8] = 1;
    sdes[9] = 7;
    memcpy(sdes + 10, FCVNC_APP_NAME, sizeof(FCVNC_APP_NAME) - 1);
    return data;
}
@end
