#import "VNCAppleFeedback.h"
#import "VNCAppleWire.h"
#import <math.h>
@implementation FCVNCAppleFeedback {
    uint32_t _receiverSSRC, _senderSSRC, _baseSequence, _highestExtendedSequence, _receivedPacketCount,
        _previousExpectedPacketCount, _previousReceivedPacketCount;
    int32_t _previousTransitTicks;
    double _jitterTicks, _senderReportReceivedTime;
    uint32_t _lastSenderReportCompactNTP;
    BOOL _sequenced;
}
- (instancetype)initWithReceiver:(uint32_t)receiver sender:(uint32_t)sender {
    if ((self = [super init])) {
        _receiverSSRC = receiver;
        _senderSSRC = sender;
    }
    return self;
}
- (void)receiveSequence:(uint16_t)sequence timestamp:(uint32_t)timestamp atTime:(double)now {
    int32_t transitTicks = (int32_t)((uint32_t)fmod(now * 90000, 4294967296.0) - timestamp);
    if (!_sequenced) {
        _baseSequence = _highestExtendedSequence = sequence;
        _sequenced = YES;
    } else {
        int16_t distance = (int16_t)(sequence - (uint16_t)_highestExtendedSequence);
        if (distance > 0)
            _highestExtendedSequence += distance;
        int64_t transitDifference = (int32_t)((uint32_t)transitTicks - (uint32_t)_previousTransitTicks);
        _jitterTicks += ((double)llabs(transitDifference) - _jitterTicks) / 16;
    }
    _previousTransitTicks = transitTicks;
    _receivedPacketCount++;
}
- (void)receiveControl:(NSData *)packet atTime:(double)now {
    const uint8_t *packetBytes = packet.bytes;
    for (NSUInteger offset = 0; packet.length - offset >= 4;) {
        const uint8_t *reportBytes = packetBytes + offset;
        NSUInteger length = 4 * (1 + ((NSUInteger)reportBytes[2] << 8 | reportBytes[3]));
        if (reportBytes[0] >> 6 != 2 || length > packet.length - offset)
            return;
        if (reportBytes[1] == 200 && length >= 28 && FCVNCRead32(reportBytes + 4) == _senderSSRC) {
            _lastSenderReportCompactNTP = FCVNCRead32(reportBytes + 8) << 16 | FCVNCRead32(reportBytes + 12) >> 16;
            _senderReportReceivedTime = now;
        }
        offset += length;
    }
}
- (NSMutableData *)reportAtTime:(double)now {
    NSUInteger reportSize = _sequenced ? 32 : 8;
    NSMutableData *data = [NSMutableData dataWithLength:reportSize + 20];
    uint8_t *packetBytes = data.mutableBytes;
    packetBytes[0] = _sequenced ? 0x81 : 0x80;
    packetBytes[1] = 201;
    packetBytes[3] = reportSize / 4 - 1;
    FCVNCWrite32(packetBytes + 4, _receiverSSRC);
    if (_sequenced) {
        uint32_t expectedPacketCount = _highestExtendedSequence - _baseSequence + 1;
        int64_t lostPacketCount = (int64_t)expectedPacketCount - _receivedPacketCount;
        uint32_t expectedInInterval = expectedPacketCount - _previousExpectedPacketCount;
        int64_t lostInInterval = (int64_t)expectedInInterval - (_receivedPacketCount - _previousReceivedPacketCount);
        int32_t cumulativeLoss = (int32_t)MAX(-8388608, MIN(8388607, lostPacketCount));
        FCVNCWrite32(packetBytes + 8, _senderSSRC);
        packetBytes[12] =
            expectedInInterval && lostInInterval > 0 ? (uint8_t)MIN(255, lostInInterval * 256 / expectedInInterval) : 0;
        packetBytes[13] = cumulativeLoss >> 16;
        packetBytes[14] = cumulativeLoss >> 8;
        packetBytes[15] = cumulativeLoss;
        FCVNCWrite32(packetBytes + 16, _highestExtendedSequence);
        FCVNCWrite32(packetBytes + 20, (uint32_t)MIN(_jitterTicks, UINT32_MAX));
        FCVNCWrite32(packetBytes + 24, _lastSenderReportCompactNTP);
        FCVNCWrite32(packetBytes + 28, _senderReportReceivedTime
                                           ? (uint32_t)MIN(MAX(0, now - _senderReportReceivedTime) * 65536, UINT32_MAX)
                                           : 0);
        _previousExpectedPacketCount = expectedPacketCount;
        _previousReceivedPacketCount = _receivedPacketCount;
    }
    uint8_t *sdes = packetBytes + reportSize;
    sdes[0] = 0x81;
    sdes[1] = 202;
    sdes[3] = 4;
    FCVNCWrite32(sdes + 4, _receiverSSRC);
    sdes[8] = 1;
    sdes[9] = 7;
    memcpy(sdes + 10, FCVNC_APP_NAME, sizeof(FCVNC_APP_NAME) - 1);
    return data;
}
@end
