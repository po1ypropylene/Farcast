#import "VNCAppleVideo.h"
#import "VNCAppleFeedback.h"
#import "VNCAppleMediaOffer.h"
#import "VNCAppleWire.h"
#import <Security/Security.h>
#import <VideoToolbox/VideoToolbox.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <srtp2/srtp.h>
#import <sys/socket.h>
#import <unistd.h>

static double Now(void) { return NSProcessInfo.processInfo.systemUptime; }

@implementation FCVNCAppleHEVC {
    NSMutableData *_fragment;
    uint16_t _nextSequence, _fragmentDecodingOrderNumber;
    uint32_t _timestamp;
    BOOL _sequenced;
    uint32_t _referenceTimestamp;
}
- (void)reset {
    _fragment = nil;
    _sequenced = NO;
    _lostReference = NO;
    _markedReference = NO;
    _referenceIdentifier = 0;
}
- (void)consumeRTP:(NSData *)packet {
    [self consumeRTPBytes:packet.bytes length:packet.length];
}
- (void)emitHeader:(const void *)header
            length:(NSUInteger)headerLength
           payload:(const void *)payload
            length:(NSUInteger)payloadLength
         timestamp:(uint32_t)timestamp
            marker:(BOOL)marker {
    if (self.onNALParts) {
        self.onNALParts(header, headerLength, payload, payloadLength, timestamp, marker);
    } else if (self.onNAL) {
        // Compatibility/test callback owns a contiguous NAL. Production consumes
        // the borrowed spans directly and makes no intermediate NAL allocation.
        NSMutableData *nal = [NSMutableData dataWithBytes:header length:headerLength];
        if (payloadLength)
            [nal appendBytes:payload length:payloadLength];
        self.onNAL(nal, timestamp, marker);
    }
}
- (void)consumeRTPBytes:(const void *)bytes length:(NSUInteger)length {
    const uint8_t *packetBytes = bytes;
    if (length < 12 || (packetBytes[0] >> 6) != 2 || (packetBytes[1] & 127) != 100)
        return;
    uint32_t timestamp = FCVNCRead32(packetBytes + 4);
    if (timestamp != _referenceTimestamp) {
        _referenceTimestamp = timestamp;
        _markedReference = NO;
    }
    NSUInteger offset = 12 + 4 * (packetBytes[0] & 15);
    if (offset > length)
        return;
    if (packetBytes[0] & 16) {
        if (length - offset < 4)
            return;
        NSUInteger extensionLength = 4 + 4 * FCVNCRead16(packetBytes + offset + 2);
        if (extensionLength > length - offset)
            return;
        // Apple's FaceTime video control header occupies the RTP extension
        // profile/length words: version in byte 0 bits 6-7; LTR mark in byte 1
        // bit 4. Unknown extension versions never create reference acknowledgements.
        unsigned version = packetBytes[offset] >> 6;
        if ((version == 1 || version == 2) && (packetBytes[offset + 1] & 0x10))
            _markedReference = YES;
        offset += extensionLength;
    }
    if (packetBytes[0] & 32) {
        uint8_t padding = packetBytes[length - 1];
        if (!padding || padding > length - offset)
            return;
        length -= padding;
    }
    uint16_t sequence = FCVNCRead16(packetBytes + 2);
    if (_sequenced && sequence != _nextSequence) {
        _fragment = nil;
        _lostReference = YES;
    }
    _sequenced = YES;
    _nextSequence = sequence + 1;
    BOOL marker = (packetBytes[1] & 128) != 0;
    NSUInteger decodingOrderNumberSize = self.decodingOrderNumbers ? 2 : 0;
    if (length - offset < 2 + decodingOrderNumberSize) {
        _lostReference = YES;
        return;
    }
    const uint8_t *payloadBytes = packetBytes + offset;
    length -= offset;
    unsigned nalType = (payloadBytes[0] >> 1) & 63;
    if ((payloadBytes[0] & 128) || !(payloadBytes[1] & 7)) {
        _lostReference = YES;
        return;
    }
    if (nalType < 48) {
        _referenceIdentifier = decodingOrderNumberSize ? FCVNCRead16(payloadBytes + 2) : timestamp;
        _fragment = nil;
        [self emitHeader:payloadBytes
                  length:2
                 payload:payloadBytes + 2 + decodingOrderNumberSize
                  length:length - 2 - decodingOrderNumberSize
               timestamp:timestamp
                  marker:marker];
    } else if (nalType == 48) {
        _referenceIdentifier = decodingOrderNumberSize ? FCVNCRead16(payloadBytes + 2) : timestamp;
        _fragment = nil;
        NSUInteger cursor = 2 + decodingOrderNumberSize;
        NSRange nalRanges[64];
        unsigned nalCount = 0;
        while (cursor < length) {
            if (length - cursor < 2) {
                _lostReference = YES;
                return;
            }
            NSUInteger nalLength = FCVNCRead16(payloadBytes + cursor);
            cursor += 2;
            if (nalLength < 2 || nalLength > length - cursor || nalCount >= 64) {
                _lostReference = YES;
                return;
            }
            nalRanges[nalCount++] = NSMakeRange(cursor, nalLength);
            cursor += nalLength;
        }
        for (unsigned i = 0; i < nalCount; i++)
            [self emitHeader:payloadBytes + nalRanges[i].location
                      length:nalRanges[i].length
                     payload:NULL
                      length:0
                   timestamp:timestamp
                      marker:marker && i + 1 == nalCount];
    } else if (nalType == 49) {
        if (length < 4 + decodingOrderNumberSize || (payloadBytes[2] & 63) >= 48 || (payloadBytes[2] & 192) == 192) {
            _lostReference = YES;
            return;
        }
        uint16_t decodingOrderNumber = decodingOrderNumberSize ? FCVNCRead16(payloadBytes + 3) : 0;
        if (payloadBytes[2] & 128) {
            uint8_t header[] = {(payloadBytes[0] & 129) | ((payloadBytes[2] & 63) << 1), payloadBytes[1]};
            _fragment = [NSMutableData dataWithBytes:header length:2];
            _fragmentDecodingOrderNumber = decodingOrderNumber;
            _timestamp = timestamp;
        }
        if (!_fragment || _fragmentDecodingOrderNumber != decodingOrderNumber || _timestamp != timestamp ||
            _fragment.length + length - 3 - decodingOrderNumberSize > 8 * 1024 * 1024) {
            _fragment = nil;
            _lostReference = YES;
            return;
        }
        [_fragment appendBytes:payloadBytes + 3 + decodingOrderNumberSize length:length - 3 - decodingOrderNumberSize];
        if (payloadBytes[2] & 64) {
            _referenceIdentifier = decodingOrderNumberSize ? _fragmentDecodingOrderNumber : timestamp;
            NSData *nal = _fragment;
            _fragment = nil;
            [self emitHeader:nal.bytes length:nal.length payload:NULL length:0 timestamp:timestamp marker:marker];
        }
    } else
        _lostReference = YES;
}
@end

typedef struct {
    NSUInteger generation, serial;
    double submitted, budget;
    uint32_t referenceIdentifier;
    BOOL markedReference;
} FCVNCAppleDecodeTicket;

enum { FCVNCReorderSlots = 128 };
typedef struct {
    uint8_t *bytes;
    NSUInteger length, capacity;
    uint16_t sequence;
} FCVNCApplePacket;

// CMBlockBuffer owns the completed access unit until VideoToolbox releases it.
static void ReleaseAccessUnit(void *owner, void *bytes, size_t size) { CFRelease(owner); }

@interface FCVNCAppleAccessUnit : NSObject
@property(nonatomic, strong) NSMutableData *bytes;
@property(nonatomic) uint32_t referenceIdentifier;
@property(nonatomic) BOOL markedReference, randomAccess;
@end
@implementation FCVNCAppleAccessUnit
@end

@implementation FCVNCAppleVideo {
    int _tcp, _socket;
    FCVNCAppleMediaOffer *_offer;
    FCVNCAppleHEVC *_hevc;
    FCVNCAppleFeedback *_feedback;
    double _lastNACK;
    BOOL _nackEnabled, _diagnosticsEnabled;
    NSMutableData *_sendKey, *_receiveKey;
    srtp_t _receive, _send;
    uint32_t _senderSSRC, _receiverSSRC;
    // Worker-owned reusable slots. A slot is borrowed only during synchronous
    // depacketization and never retained by a callback or VideoToolbox.
    FCVNCApplePacket _reorder[FCVNCReorderSlots];
    NSUInteger _reorderCount;
    uint8_t _receivePacket[65536];
    NSMutableArray<FCVNCAppleAccessUnit *> *_readyUnits;
    double _keyframeInterval;
    uint16_t _nextSequence;
    BOOL _sequenced, _needsReferenceRecovery, _longTermReference, _hasAcknowledgement;
    uint32_t _acknowledgedReference;
    double _gapSince, _lastFeedback, _started, _lastFrame, _lastKeyframe;
    uint32_t _timestamp, _accessUnitReferenceIdentifier;
    NSMutableData *_accessUnit;
    NSData *_videoParameterSet, *_sequenceParameterSet, *_pictureParameterSet;
    CMVideoFormatDescriptionRef _format;
    VTDecompressionSessionRef _decoder;
    // All protocol state belongs to the VNC worker. Only these callback/mailbox
    // fields are shared with VideoToolbox and always accessed under this lock.
    CVPixelBufferRef _pendingBuffer;
    NSNumber *_pendingAcknowledgement;
    BOOL _decodeFailed, _decoderWarm;
    NSUInteger _inFlightDecodes, _decodeGeneration, _submittedDecodeCount, _lastCompletedDecodeSerial;
    double _decodeProgressTime;
    NSUInteger _datagrams, _authenticatedPackets, _nalCount, _rtcpPackets, _otherPackets;
    int _lastAuthenticationError;
    uint64_t _nalTypes;
    NSUInteger _markerNALs;
    OSStatus _formatStatus, _decodeStatus;
}
- (instancetype)initWithTCPDescriptor:(int)tcp {
    if (!(self = [super init]))
        return nil;
    _tcp = tcp;
    _socket = -1;
    _diagnosticsEnabled = [NSProcessInfo.processInfo.environment[@"FARCAST_VNC_DIAGNOSTICS"] isEqual:@"1"];
    static dispatch_once_t once;
    static srtp_err_status_t status;
    dispatch_once(&once, ^{
      status = srtp_init();
    });
    if (status != srtp_err_status_ok)
        return nil;
    _hevc = [FCVNCAppleHEVC new];
    __weak FCVNCAppleVideo *weak = self;
    _hevc.onNALParts = ^(const void *header, NSUInteger headerLength, const void *payload, NSUInteger payloadLength,
                         uint32_t timestamp, BOOL marker) {
      [weak nalHeader:header
               length:headerLength
              payload:payload
               length:payloadLength
            timestamp:timestamp
               marker:marker];
    };
    _readyUnits = [NSMutableArray array];
    _keyframeInterval = .15;
    return self;
}
- (void)retireDecoder {
    [_readyUnits removeAllObjects];
    _hasAcknowledgement = NO;
    @synchronized(self) {
        _decodeGeneration++;
        _decoderWarm = NO;
        _pendingAcknowledgement = nil;
        if (_pendingBuffer)
            CVPixelBufferRelease(_pendingBuffer);
        _pendingBuffer = NULL;
    }
    if (_decoder) {
        VTDecompressionSessionWaitForAsynchronousFrames(_decoder);
        VTDecompressionSessionInvalidate(_decoder);
        CFRelease(_decoder);
        _decoder = NULL;
    }
    if (_format) {
        CFRelease(_format);
        _format = NULL;
    }
}
- (void)close {
    if (_socket >= 0) {
        close(_socket);
        _socket = -1;
    }
    if (_receive) {
        srtp_dealloc(_receive);
        _receive = NULL;
    }
    if (_send) {
        srtp_dealloc(_send);
        _send = NULL;
    }
    [self retireDecoder];
    if (_sendKey)
        memset_s(_sendKey.mutableBytes, _sendKey.length, 0, _sendKey.length);
    if (_receiveKey)
        memset_s(_receiveKey.mutableBytes, _receiveKey.length, 0, _receiveKey.length);
    _sendKey = nil;
    _receiveKey = nil;
    for (unsigned i = 0; i < FCVNCReorderSlots; i++) {
        free(_reorder[i].bytes);
        _reorder[i] = (FCVNCApplePacket){0};
    }
    _offer = nil;
    _feedback = nil;
    _videoParameterSet = nil;
    _sequenceParameterSet = nil;
    _pictureParameterSet = nil;
    _accessUnit = nil;
    @synchronized(self) {
        if (_pendingBuffer)
            CVPixelBufferRelease(_pendingBuffer);
        _pendingBuffer = NULL;
        _decodeFailed = NO;
        _inFlightDecodes = 0;
    }
    [self clearPackets];
    [_hevc reset];
    [_readyUnits removeAllObjects];
    _keyframeInterval = .15;
    _sequenced = NO;
    _datagrams = 0;
    _authenticatedPackets = 0;
    _nalCount = 0;
    _rtcpPackets = 0;
    _otherPackets = 0;
    _lastAuthenticationError = 0;
    _nalTypes = 0;
    _markerNALs = 0;
    _formatStatus = 0;
    _decodeStatus = 0;
    _receivedFrame = NO;
    _hasAcknowledgement = NO;
    _longTermReference = NO;
    _nackEnabled = NO;
    _needsReferenceRecovery = YES;
}
- (void)dealloc {
    [self close];
}
- (NSData *)configure:(NSData *)request width:(NSUInteger)width height:(NSUInteger)height {
    [self close];
    _failure = nil;
    const uint8_t *requestBytes = request.bytes;
    if (request.length != 38 || FCVNCRead16(requestBytes) != 36 || FCVNCRead16(requestBytes + 2) != 1 ||
        FCVNCRead16(requestBytes + 4) != 1 || !(FCVNCRead32(requestBytes + 18) & 1))
        return nil;
    uint16_t mediaPort = FCVNCRead16(requestBytes + 16);
    if (!mediaPort)
        return nil;
    struct sockaddr_storage peer = {0}, local = {0};
    socklen_t peerLength = sizeof(peer), localLength = sizeof(local);
    if (getpeername(_tcp, (struct sockaddr *)&peer, &peerLength) ||
        getsockname(_tcp, (struct sockaddr *)&local, &localLength))
        return nil;
    if (peer.ss_family == AF_INET) {
        ((struct sockaddr_in *)&peer)->sin_port = htons(mediaPort);
        ((struct sockaddr_in *)&local)->sin_port = htons(mediaPort);
    } else if (peer.ss_family == AF_INET6) {
        ((struct sockaddr_in6 *)&peer)->sin6_port = htons(mediaPort);
        ((struct sockaddr_in6 *)&local)->sin6_port = htons(mediaPort);
    } else
        return nil;
    _socket = socket(peer.ss_family, SOCK_DGRAM, 0);
    if (_socket < 0)
        return nil;
    // Bound kernel backlog without assuming dependent HEVC pictures can be
    // skipped independently. Overflow follows the authenticated loss/IRAP path.
    int receiveBufferSize = 512 * 1024;
    setsockopt(_socket, SOL_SOCKET, SO_RCVBUF, &receiveBufferSize, sizeof(receiveBufferSize));
    if (bind(_socket, (struct sockaddr *)&local, localLength) ||
        connect(_socket, (struct sockaddr *)&peer, peerLength) || fcntl(_socket, F_SETFL, O_NONBLOCK) < 0) {
        _failure = @"Adaptive video could not bind its UDP port.";
        [self close];
        return nil;
    }
    _offer = [[FCVNCAppleMediaOffer alloc] initWithWidth:width height:height];
    _sendKey = [NSMutableData dataWithLength:46];
    _receiveKey = [NSMutableData dataWithLength:46];
    if (!_offer || SecRandomCopyBytes(kSecRandomDefault, 46, _sendKey.mutableBytes) != errSecSuccess ||
        SecRandomCopyBytes(kSecRandomDefault, 46, _receiveKey.mutableBytes) != errSecSuccess) {
        [self close];
        return nil;
    }
    _receiverSSRC = _offer.receiverSSRC;
    _started = Now();
    _lastFrame = _started;
    _lastFeedback = 0;
    _lastKeyframe = 0;
    return [_offer configurationWithSendKey:_sendKey receiveKey:_receiveKey];
}
- (BOOL)acceptAnswer:(NSData *)answer {
    const uint8_t *answerBytes = answer.bytes;
    if (!_offer || answer.length < 20 || FCVNCRead16(answerBytes) + 2 != answer.length ||
        FCVNCRead16(answerBytes + 2) != 2 || FCVNCRead16(answerBytes + 4) != 2)
        return NO;
    NSUInteger audioAnswerLength = FCVNCRead16(answerBytes + 10), videoAnswerLength = FCVNCRead16(answerBytes + 12);
    if (FCVNCRead16(answerBytes + 14) || 20 + audioAnswerLength + videoAnswerLength != answer.length ||
        !videoAnswerLength)
        return NO;
    BOOL decodingOrderNumbers = NO;
    if (![FCVNCAppleMediaOffer
               acceptVideoAnswer:[answer subdataWithRange:NSMakeRange(20 + audioAnswerLength, videoAnswerLength)]
                      senderSSRC:&_senderSSRC
            decodingOrderNumbers:&decodingOrderNumbers
               longTermReference:&_longTermReference
                   allowFeedback:&_nackEnabled])
        return NO;
    _hevc.decodingOrderNumbers = decodingOrderNumbers;
    srtp_policy_t policy = {0};
    srtp_crypto_policy_set_aes_cm_256_hmac_sha1_80(&policy.rtp);
    srtp_crypto_policy_set_aes_cm_256_hmac_sha1_80(&policy.rtcp);
    policy.ssrc.type = ssrc_specific;
    policy.ssrc.value = _senderSSRC;
    policy.key = _receiveKey.mutableBytes;
    policy.window_size = 512;
    if (srtp_create(&_receive, &policy) != srtp_err_status_ok)
        return NO;
    policy.ssrc.value = _receiverSSRC;
    policy.key = _sendKey.mutableBytes;
    if (srtp_create(&_send, &policy) != srtp_err_status_ok) {
        srtp_dealloc(_receive);
        _receive = NULL;
        return NO;
    }
    _offer = nil;
    _feedback = [[FCVNCAppleFeedback alloc] initWithReceiver:_receiverSSRC sender:_senderSSRC];
    _lastNACK = 0;
    [self feedback:YES];
    return YES;
}
- (void)requestRefresh {
    // A display-layout change needs a fresh picture even on an otherwise idle
    // desktop. Do not wait for remote pointer damage to wake screen capture.
    _lastKeyframe = 0;
    _keyframeInterval = .15;
    [self feedback:YES];
}
- (void)feedback:(BOOL)keyframe {
    if (!_send || _socket < 0)
        return;
    double now = Now();
    if (keyframe && now - _lastKeyframe < _keyframeInterval)
        return;
    NSMutableData *packet = [self receiverReport:now];
    if (keyframe) {
        uint8_t fir[8] = {0x80, 192, 0, 1};
        FCVNCWrite32(fir + 4, _receiverSSRC);
        [packet appendBytes:fir length:sizeof(fir)];
        _keyframeInterval = _lastKeyframe ? MIN(.6, _keyframeInterval * 2) : .15;
        _lastKeyframe = now;
    }
    [self sendControl:packet];
    _lastFeedback = now;
}
- (NSMutableData *)receiverReport:(double)now {
    NSMutableData *packet = [_feedback reportAtTime:now];
    if (_longTermReference && _hasAcknowledgement) {
        // AVConference APP name 5 carries the decoded reference identifier:
        // DON for negotiated interleaving, RTP timestamp otherwise. It is never
        // a locally generated arrival/frame counter.
        // Keep the last good acknowledgement while recovering; missing, stale,
        // failed and merely submitted pictures must never advance it.
        uint8_t ack[16] = {0x80, 204, 0, 3};
        FCVNCWrite32(ack + 4, _receiverSSRC);
        FCVNCWrite32(ack + 8, 5);
        FCVNCWrite32(ack + 12, _acknowledgedReference);
        [packet appendBytes:ack length:sizeof(ack)];
    }
    return packet;
}
- (void)sendControl:(NSData *)clear {
    NSMutableData *packet = [NSMutableData dataWithLength:clear.length + 64];
    memcpy(packet.mutableBytes, clear.bytes, clear.length);
    int length = (int)clear.length;
    if (srtp_protect_rtcp(_send, packet.mutableBytes, &length) == srtp_err_status_ok)
        send(_socket, packet.bytes, length, 0);
}
- (void)requestMissingPackets {
    double now = Now();
    if (!_nackEnabled || !_reorderCount || !_gapSince || now - _gapSince < .005 || now - _lastNACK < .015)
        return;
    // RFC 4585 generic NACK: request original sequence numbers within the
    // bounded reorder window. No unnegotiated RTX SSRC/payload is accepted.
    NSMutableData *packet = [self receiverReport:now];
    uint8_t nack[12 + 8 * 4] = {0x81, 205};
    FCVNCWrite32(nack + 4, _receiverSSRC);
    FCVNCWrite32(nack + 8, _senderSSRC);
    unsigned highest = 0;
    for (unsigned i = 0; i < FCVNCReorderSlots; i++)
        if (_reorder[i].length)
            highest = MAX(highest, (uint16_t)(_reorder[i].sequence - _nextSequence));
    unsigned count = 0;
    for (unsigned offset = 0; offset < highest && count < 8;) {
        uint16_t missing = _nextSequence + offset;
        if ([self packetForSequence:missing]) {
            offset++;
            continue;
        }
        uint16_t mask = 0;
        for (unsigned bit = 0; bit < 16 && offset + bit + 1 < highest; bit++)
            if (![self packetForSequence:(uint16_t)(missing + bit + 1)])
                mask |= 1 << bit;
        FCVNCWrite16(nack + 12 + count * 4, missing);
        FCVNCWrite16(nack + 14 + count * 4, mask);
        count++;
        offset += 17;
    }
    if (count) {
        FCVNCWrite16(nack + 2, 2 + count);
        [packet appendBytes:nack length:12 + count * 4];
        [self sendControl:packet];
        _lastNACK = now;
        _lastFeedback = now;
    }
}
- (int)socketDescriptor {
    return _receive ? _socket : -1;
}
- (void)pump {
    if (_socket < 0)
        return;
    if (!_receive) {
        if (_started && Now() - _started > 8)
            _failure = @"Adaptive negotiation timed out.";
        return;
    }
    for (unsigned budget = 0; budget < 256; budget++) {
        uint8_t *packet = _receivePacket;
        ssize_t count = recv(_socket, packet, sizeof(_receivePacket), 0);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (_diagnosticsEnabled && !_receivedFrame)
            _datagrams++;
        if (count < 12 || (packet[0] >> 6) != 2) {
            if (_diagnosticsEnabled && !_receivedFrame)
                _otherPackets++;
            continue;
        }
        int length = (int)count;
        BOOL rtcp = packet[1] >= 192 && packet[1] <= 223;
        srtp_err_status_t result =
            rtcp ? srtp_unprotect_rtcp(_receive, packet, &length) : srtp_unprotect(_receive, packet, &length);
        if (result != srtp_err_status_ok) {
            _lastAuthenticationError = result;
            continue;
        }
        if (rtcp) {
            if (_diagnosticsEnabled && !_receivedFrame)
                _rtcpPackets++;
            [_feedback receiveControl:[NSData dataWithBytes:packet length:length] atTime:Now()];
            continue;
        }
        if (length < 12 || (packet[1] & 127) != 100)
            continue;
        if (_diagnosticsEnabled && !_receivedFrame)
            _authenticatedPackets++;
        uint16_t sequence = FCVNCRead16(packet + 2);
        [_feedback receiveSequence:sequence timestamp:FCVNCRead32(packet + 4) atTime:Now()];
        if (!_sequenced) {
            _nextSequence = sequence;
            _sequenced = YES;
        }
        int16_t distance = (int16_t)(sequence - _nextSequence);
        if (distance < 0)
            continue;
        if (distance >= 128) {
            [self clearPackets];
            [_hevc reset];
            _nextSequence = sequence;
            _accessUnit = nil;
            _needsReferenceRecovery = YES;
            [self feedback:YES];
        }
        FCVNCApplePacket *slot = &_reorder[sequence % FCVNCReorderSlots];
        if (!slot->length)
            _reorderCount++;
        if (slot->capacity < (NSUInteger)length) {
            NSUInteger capacity = MAX(2048, (NSUInteger)length);
            uint8_t *storage = realloc(slot->bytes, capacity);
            if (!storage) {
                _failure = @"Adaptive packet storage is unavailable.";
                return;
            }
            slot->bytes = storage;
            slot->capacity = capacity;
        }
        memcpy(slot->bytes, packet, length);
        slot->length = length;
        slot->sequence = sequence;
        [self drainPackets];
    }
    double now = Now();
    [self requestMissingPackets];
    if (_reorderCount && _gapSince && now - _gapSince > (_nackEnabled ? .075 : .025)) {
        // A small reorder window bounds latency and memory. Missing references
        // recover at an IDR rather than presenting corrupted dependent pictures.
        uint16_t nearest = _nextSequence;
        unsigned distance = UINT16_MAX;
        for (unsigned i = 0; i < FCVNCReorderSlots; i++) {
            if (!_reorder[i].length)
                continue;
            unsigned sequenceDistance = (uint16_t)(_reorder[i].sequence - _nextSequence);
            if (sequenceDistance < distance) {
                nearest = _reorder[i].sequence;
                distance = sequenceDistance;
            }
        }
        _nextSequence = nearest;
        _needsReferenceRecovery = YES;
        _accessUnit = nil;
        [_hevc reset];
        [self feedback:YES];
        [self drainPackets];
    }
    // Collect complete pictures during the receive burst before paying decode
    // cost. Keep dependencies intact, or skip only to a complete random-access unit.
    NSArray<FCVNCAppleAccessUnit *> *ready = [_readyUnits copy];
    [_readyUnits removeAllObjects];
    for (FCVNCAppleAccessUnit *unit in ready)
        [self submitAccessUnit:unit];
    CVPixelBufferRef buffer = NULL;
    BOOL failed;
    NSNumber *acknowledgement;
    @synchronized(self) {
        failed = _decodeFailed || (_inFlightDecodes && now - _decodeProgressTime > (_decoderWarm ? .1 : 1));
        _decodeFailed = NO;
        if (failed) {
            _decodeGeneration++;
            _pendingAcknowledgement = nil;
            if (_pendingBuffer)
                CVPixelBufferRelease(_pendingBuffer);
            _pendingBuffer = NULL;
        }
        buffer = _pendingBuffer;
        acknowledgement = _pendingAcknowledgement;
        _pendingAcknowledgement = nil;
        _pendingBuffer = NULL;
    }
    if (failed) {
        _needsReferenceRecovery = YES;
        _accessUnit = nil;
    }
    if (acknowledgement) {
        _acknowledgedReference = acknowledgement.unsignedIntValue;
        _hasAcknowledgement = YES;
    }
    // Retry after every loss with 150/300/600 ms backoff, including after startup.
    BOOL repairingGap = _reorderCount && _gapSince && now - _gapSince <= (_nackEnabled ? .075 : .025);
    if ((_needsReferenceRecovery || !_receivedFrame) && !repairingGap)
        [self feedback:YES];
    else if (now - _lastFeedback > .2)
        [self feedback:NO];
    if (buffer) {
        if (self.onFrame)
            self.onFrame(buffer);
        CVPixelBufferRelease(buffer);
        _receivedFrame = YES;
        _lastFrame = now;
        _keyframeInterval = .15;
    }
    if (!_receivedFrame && now - _started > 8) {
        _failure =
            !_diagnosticsEnabled
                ? @"Adaptive video did not deliver a decoded frame before its startup deadline."
                : [NSString
                      stringWithFormat:
                          @"Adaptive video: %lu datagrams, %lu authenticated video, %lu control, %lu NALs, %lu marked, "
                          @"types "
                          @"%llx, parameters %lu/%lu/%lu, format %d, decode %d, authentication %d, no decoded frame.",
                          (unsigned long)_datagrams, (unsigned long)_authenticatedPackets, (unsigned long)_rtcpPackets,
                          (unsigned long)_nalCount, (unsigned long)_markerNALs, (unsigned long long)_nalTypes,
                          (unsigned long)_videoParameterSet.length, (unsigned long)_sequenceParameterSet.length,
                          (unsigned long)_pictureParameterSet.length, (int)_formatStatus, (int)_decodeStatus,
                          _lastAuthenticationError];
    }
    if (_receivedFrame && _needsReferenceRecovery && now - _lastFrame > 8)
        _failure = @"Adaptive video could not recover its reference pictures.";
}
- (FCVNCApplePacket *)packetForSequence:(uint16_t)sequence {
    FCVNCApplePacket *packet = &_reorder[sequence % FCVNCReorderSlots];
    return packet->length && packet->sequence == sequence ? packet : NULL;
}
- (void)clearPackets {
    for (unsigned i = 0; i < FCVNCReorderSlots; i++)
        _reorder[i].length = 0;
    _reorderCount = 0;
    _gapSince = 0;
}
- (void)drainPackets {
    FCVNCApplePacket *slot;
    while ((slot = [self packetForSequence:_nextSequence])) {
        _nextSequence++;
        [_hevc consumeRTPBytes:slot->bytes length:slot->length];
        slot->length = 0;
        _reorderCount--;
        if (_hevc.lostReference) {
            _needsReferenceRecovery = YES;
            _accessUnit = nil;
            [_readyUnits removeAllObjects];
            [self feedback:YES];
            [_hevc reset];
        }
    }
    _gapSince = _reorderCount ? (_gapSince ?: Now()) : 0;
}
- (BOOL)prepareDecoder {
    if (_decoder)
        return YES;
    if (!_videoParameterSet || !_sequenceParameterSet || !_pictureParameterSet)
        return NO;
    if (_format) {
        CFRelease(_format);
        _format = NULL;
    }
    const uint8_t *parameterSets[] = {_videoParameterSet.bytes, _sequenceParameterSet.bytes,
                                      _pictureParameterSet.bytes};
    size_t parameterSetLengths[] = {_videoParameterSet.length, _sequenceParameterSet.length,
                                    _pictureParameterSet.length};
    _formatStatus = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, 3, parameterSets,
                                                                        parameterSetLengths, 4, NULL, &_format);
    if (_formatStatus)
        return NO;
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(_format);
    if (dimensions.width <= 0 || dimensions.height <= 0 || dimensions.width > 3840 || dimensions.height > 2160)
        return NO;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    NSDictionary *specification = @{(id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder : @YES};
    OSStatus status =
        VTDecompressionSessionCreate(kCFAllocatorDefault, _format, (__bridge CFDictionaryRef)specification,
                                     (__bridge CFDictionaryRef)attributes, NULL, &_decoder);
    if (status) {
        _failure = @"Hardware HEVC decoding is unavailable for this stream.";
        return NO;
    }
    VTSessionSetProperty(_decoder, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    return YES;
}
- (void)nalHeader:(const void *)header
           length:(NSUInteger)headerLength
          payload:(const void *)payload
           length:(NSUInteger)payloadLength
        timestamp:(uint32_t)timestamp
           marker:(BOOL)marker {
    NSUInteger length = headerLength + payloadLength;
    const uint8_t *headerBytes = header;
    if (headerLength < 2 || length > 8 * 1024 * 1024)
        return;
    if (_diagnosticsEnabled && !_receivedFrame)
        _nalCount++;
    unsigned nalType = (headerBytes[0] >> 1) & 63;
    if (_diagnosticsEnabled && !_receivedFrame)
        _nalTypes |= UINT64_C(1) << nalType;
    if (_diagnosticsEnabled && marker && !_receivedFrame)
        _markerNALs++;
    if (nalType == 32 || nalType == 33 || nalType == 34) {
        if (length > 65535)
            return;
        NSMutableData *nal = [NSMutableData dataWithBytes:header length:headerLength];
        if (payloadLength)
            [nal appendBytes:payload length:payloadLength];
        NSData *previous = nalType == 32   ? _videoParameterSet
                           : nalType == 33 ? _sequenceParameterSet
                                           : _pictureParameterSet;
        if (![previous isEqualToData:nal]) {
            [self retireDecoder];
            _needsReferenceRecovery = YES;
            _accessUnit = nil;
            if (nalType == 32)
                _videoParameterSet = nal;
            else if (nalType == 33)
                _sequenceParameterSet = nal;
            else
                _pictureParameterSet = nal;
        }
        return;
    }
    if (nalType > 31)
        return;
    BOOL randomAccess = nalType >= 16 && nalType <= 21;
    // With negotiated LTR the hardware decoder retains acknowledged reference
    // pictures. Try complete dependent pictures; failure still requests FIR.
    if (_needsReferenceRecovery && !randomAccess && !(_longTermReference && _hasAcknowledgement))
        return;
    if (!_accessUnit || _timestamp != timestamp) {
        // HEVC first_slice_segment_in_pic_flag is the first RBSP bit. After
        // packet loss, a later slice cannot stand in for a complete picture or
        // become an acknowledged LTR, even if the hardware conceals the damage.
        if (length < 3 || !((headerLength > 2 ? headerBytes[2] : ((const uint8_t *)payload)[0]) & 0x80)) {
            _accessUnit = nil;
            _needsReferenceRecovery = YES;
            return;
        }
        _accessUnit = [NSMutableData data];
        _timestamp = timestamp;
        _accessUnitReferenceIdentifier = _hevc.referenceIdentifier;
    }
    if (_accessUnit.length + length + 4 > 8 * 1024 * 1024) {
        _accessUnit = nil;
        _needsReferenceRecovery = YES;
        return;
    }
    uint8_t nalLengthBytes[4];
    FCVNCWrite32(nalLengthBytes, (uint32_t)length);
    [_accessUnit appendBytes:nalLengthBytes length:4];
    [_accessUnit appendBytes:header length:headerLength];
    if (payloadLength)
        [_accessUnit appendBytes:payload length:payloadLength];
    if (!marker)
        return;
    FCVNCAppleAccessUnit *unit = [FCVNCAppleAccessUnit new];
    unit.bytes = _accessUnit;
    unit.referenceIdentifier = _accessUnitReferenceIdentifier;
    unit.markedReference = _hevc.markedReference;
    unit.randomAccess = randomAccess;
    _accessUnit = nil;
    // On overload, discard work preceding the newest IRAP. Never independently
    // skip P pictures and then display their descendants with missing references.
    if (randomAccess && _readyUnits.count)
        [_readyUnits removeAllObjects];
    if (_readyUnits.count >= 3) {
        [_readyUnits removeAllObjects];
        _needsReferenceRecovery = YES;
        @synchronized(self) {
            _decodeGeneration++;
        }
        [self feedback:YES];
        return;
    }
    [_readyUnits addObject:unit];
}
- (void)submitAccessUnit:(FCVNCAppleAccessUnit *)unit {
    if (_needsReferenceRecovery && !unit.randomAccess && !(_longTermReference && _hasAcknowledgement))
        return;
    if (![self prepareDecoder])
        return;
    FCVNCAppleDecodeTicket ticket = {
        .submitted = Now(), .referenceIdentifier = unit.referenceIdentifier, .markedReference = unit.markedReference};
    @synchronized(self) {
        // Never build an unbounded decoder queue. Dropping a reference picture
        // requires recovery at an IRAP; decoding only the latest P frame is unsafe.
        if (_inFlightDecodes >= 3) {
            _decodeGeneration++;
            _needsReferenceRecovery = YES;
            _accessUnit = nil;
            return;
        }
        if (!_inFlightDecodes)
            _decodeProgressTime = Now();
        _inFlightDecodes++;
        ticket.generation = _decodeGeneration;
        ticket.budget = _decoderWarm ? .1 : 1;
        ticket.serial = ++_submittedDecodeCount;
    }
    _needsReferenceRecovery = NO;
    CMBlockBufferRef block = NULL;
    CMSampleBufferRef sample = NULL;
    size_t length = unit.bytes.length;
    void *owner = (void *)CFBridgingRetain(unit.bytes);
    CMBlockBufferCustomBlockSource source = {
        .version = kCMBlockBufferCustomBlockSourceVersion, .FreeBlock = ReleaseAccessUnit, .refCon = owner};
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, unit.bytes.mutableBytes, length,
                                                         kCFAllocatorNull, &source, 0, length, 0, &block);
    if (status)
        CFRelease(owner);
    if (!status)
        status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _format, 1, 0, NULL, 1, &length, &sample);
    if (!status) {
        __weak FCVNCAppleVideo *weak = self;
        status = VTDecompressionSessionDecodeFrameWithOutputHandler(
            _decoder, sample, kVTDecodeFrame_EnableAsynchronousDecompression | kVTDecodeFrame_1xRealTimePlayback, NULL,
            ^(OSStatus result, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime pts, CMTime duration) {
              [weak decoded:image status:result ticket:ticket];
            });
    }
    if (sample)
        CFRelease(sample);
    if (block)
        CFRelease(block);
    _accessUnit = nil;
    _decodeStatus = status;
    if (status) {
        @synchronized(self) {
            _inFlightDecodes--;
        }
        _needsReferenceRecovery = YES;
        [self feedback:YES];
    }
}
- (void)decoded:(CVImageBufferRef)image status:(OSStatus)status ticket:(FCVNCAppleDecodeTicket)ticket {
    @synchronized(self) {
        _inFlightDecodes--;
        _decodeProgressTime = Now();
        if (ticket.generation != _decodeGeneration || ticket.serial <= _lastCompletedDecodeSerial)
            return;
        OSType pixelFormat = image ? CVPixelBufferGetPixelFormatType(image) : 0;
        if (status || !image || Now() - ticket.submitted > ticket.budget ||
            (pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
             pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)) {
            _decodeFailed = YES;
            return;
        }
        NSUInteger width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image);
        if (!width || !height || width > 3840 || height > 2160) {
            _decodeFailed = YES;
            return;
        }
        // Retain the IOSurface until the latest-frame mailbox/Metal command
        // finishes with it. No base-address lock, frame allocation or CPU copy.
        if (_pendingBuffer)
            CVPixelBufferRelease(_pendingBuffer);
        _decoderWarm = YES;
        _pendingBuffer = CVPixelBufferRetain(image);
        if (ticket.markedReference)
            _pendingAcknowledgement = @(ticket.referenceIdentifier);
        _lastCompletedDecodeSerial = ticket.serial;
    }
}
@end
