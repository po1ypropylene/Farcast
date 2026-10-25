#import "VNCAppleVideo.h"
#import "VNCAppleMediaOffer.h"
#import <Security/Security.h>
#import <VideoToolbox/VideoToolbox.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <srtp2/srtp.h>
#import <sys/socket.h>
#import <unistd.h>

static uint16_t U16(const uint8_t *p) { return (uint16_t)p[0] << 8 | p[1]; }
static uint32_t U32(const uint8_t *p) { return (uint32_t)U16(p) << 16 | U16(p + 2); }
static void W16(uint8_t *p, uint16_t n) {
    p[0] = n >> 8;
    p[1] = n;
}
static void W32(uint8_t *p, uint32_t n) {
    W16(p, n >> 16);
    W16(p + 2, n);
}
static double Now(void) { return NSProcessInfo.processInfo.systemUptime; }

@implementation FCVNCAppleHEVC {
    NSMutableData *_fragment;
    uint16_t _nextSequence, _don;
    uint32_t _timestamp;
    BOOL _sequenced;
}
- (void)reset {
    _fragment = nil;
    _sequenced = NO;
    _lostReference = NO;
}
- (void)consumeRTP:(NSData *)packet {
    const uint8_t *p = packet.bytes;
    NSUInteger length = packet.length;
    if (length < 12 || (p[0] >> 6) != 2 || (p[1] & 127) != 100)
        return;
    NSUInteger offset = 12 + 4 * (p[0] & 15);
    if (offset > length)
        return;
    if (p[0] & 16) {
        NSUInteger donBytes = self.decodingOrderNumbers ? 2 : 0;
        if (length - offset < 2 + donBytes)
            return;
        NSUInteger extension = 4 + 4 * U16(p + offset + 2);
        if (extension > length - offset)
            return;
        offset += extension;
    }
    if (p[0] & 32) {
        uint8_t padding = p[length - 1];
        if (!padding || padding > length - offset)
            return;
        length -= padding;
    }
    uint16_t sequence = U16(p + 2);
    uint32_t timestamp = U32(p + 4);
    if (_sequenced && sequence != _nextSequence) {
        _fragment = nil;
        _lostReference = YES;
    }
    _sequenced = YES;
    _nextSequence = sequence + 1;
    BOOL marker = (p[1] & 128) != 0;
    NSUInteger donBytes = self.decodingOrderNumbers ? 2 : 0;
    if (length - offset < 2 + donBytes) {
        _lostReference = YES;
        return;
    }
    p += offset;
    length -= offset;
    unsigned type = (p[0] >> 1) & 63;
    if ((p[0] & 128) || !(p[1] & 7)) {
        _lostReference = YES;
        return;
    }
    if (type < 48) {
        _fragment = nil;
        NSMutableData *nal = [NSMutableData dataWithBytes:p length:2];
        [nal appendBytes:p + 2 + donBytes length:length - 2 - donBytes];
        if (self.onNAL)
            self.onNAL(nal, timestamp, marker);
    } else if (type == 48) {
        _fragment = nil;
        NSUInteger cursor = 2 + donBytes;
        NSMutableArray<NSData *> *nals = [NSMutableArray array];
        while (cursor < length) {
            if (length - cursor < 2) {
                _lostReference = YES;
                return;
            }
            NSUInteger size = U16(p + cursor);
            cursor += 2;
            if (size < 2 || size > length - cursor || nals.count >= 64) {
                _lostReference = YES;
                return;
            }
            [nals addObject:[NSData dataWithBytes:p + cursor length:size]];
            cursor += size;
        }
        for (NSUInteger i = 0; i < nals.count; i++)
            if (self.onNAL)
                self.onNAL(nals[i], timestamp, marker && i + 1 == nals.count);
    } else if (type == 49) {
        if (length < 4 + donBytes || (p[2] & 63) >= 48 || (p[2] & 192) == 192) {
            _lostReference = YES;
            return;
        }
        uint16_t don = donBytes ? U16(p + 3) : 0;
        if (p[2] & 128) {
            uint8_t header[] = {(p[0] & 129) | ((p[2] & 63) << 1), p[1]};
            _fragment = [NSMutableData dataWithBytes:header length:2];
            _don = don;
            _timestamp = timestamp;
        }
        if (!_fragment || _don != don || _timestamp != timestamp ||
            _fragment.length + length - 3 - donBytes > 8 * 1024 * 1024) {
            _fragment = nil;
            _lostReference = YES;
            return;
        }
        [_fragment appendBytes:p + 3 + donBytes length:length - 3 - donBytes];
        if (p[2] & 64) {
            NSData *nal = _fragment;
            _fragment = nil;
            if (self.onNAL)
                self.onNAL(nal, timestamp, marker);
        }
    } else
        _lostReference = YES;
}
@end

@interface FCVNCAppleVideo ()
- (void)decoded:(CVImageBufferRef)image status:(OSStatus)status;
@end
static void Decoded(void *context, void *source, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef image,
                    CMTime presentation, CMTime duration) {
    [(__bridge FCVNCAppleVideo *)context decoded:image status:status];
}
@implementation FCVNCAppleVideo {
    int _tcp, _socket;
    FCVNCAppleMediaOffer *_offer;
    FCVNCAppleHEVC *_hevc;
    NSMutableData *_sendKey, *_receiveKey;
    srtp_t _receive, _send;
    uint32_t _senderSSRC, _receiverSSRC;
    NSMutableDictionary<NSNumber *, NSData *> *_reorder;
    uint16_t _nextSequence;
    BOOL _sequenced, _waitingForIDR;
    double _gapSince, _lastFeedback, _started, _lastFrame, _lastKeyframe;
    uint32_t _timestamp;
    NSMutableData *_accessUnit;
    NSData *_vps, *_sps, *_pps;
    CMVideoFormatDescriptionRef _format;
    VTDecompressionSessionRef _decoder;
    NSData *_pendingPixels;
    NSInteger _pendingWidth, _pendingHeight, _pendingStride;
    BOOL _decodeFailed;
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
    static dispatch_once_t once;
    static srtp_err_status_t status;
    dispatch_once(&once, ^{
      status = srtp_init();
    });
    if (status != srtp_err_status_ok)
        return nil;
    _hevc = [FCVNCAppleHEVC new];
    __weak FCVNCAppleVideo *weak = self;
    _hevc.onNAL = ^(NSData *nal, uint32_t timestamp, BOOL marker) {
      [weak nal:nal timestamp:timestamp marker:marker];
    };
    _reorder = [NSMutableDictionary dictionary];
    return self;
}
- (void)retireDecoder {
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
    _offer = nil;
    _vps = nil;
    _sps = nil;
    _pps = nil;
    _accessUnit = nil;
    @synchronized(self) {
        _pendingPixels = nil;
    }
    [_reorder removeAllObjects];
    [_hevc reset];
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
    _waitingForIDR = YES;
}
- (void)dealloc {
    [self close];
}
- (NSData *)configure:(NSData *)request width:(NSUInteger)width height:(NSUInteger)height {
    [self close];
    _failure = nil;
    const uint8_t *p = request.bytes;
    if (request.length != 38 || U16(p) != 36 || U16(p + 2) != 1 || U16(p + 4) != 1 || !(U32(p + 18) & 1))
        return nil;
    uint16_t port = U16(p + 16);
    if (!port)
        return nil;
    struct sockaddr_storage peer = {0}, local = {0};
    socklen_t peerLength = sizeof(peer), localLength = sizeof(local);
    if (getpeername(_tcp, (struct sockaddr *)&peer, &peerLength) ||
        getsockname(_tcp, (struct sockaddr *)&local, &localLength))
        return nil;
    if (peer.ss_family == AF_INET) {
        ((struct sockaddr_in *)&peer)->sin_port = htons(port);
        ((struct sockaddr_in *)&local)->sin_port = htons(port);
    } else if (peer.ss_family == AF_INET6) {
        ((struct sockaddr_in6 *)&peer)->sin6_port = htons(port);
        ((struct sockaddr_in6 *)&local)->sin6_port = htons(port);
    } else
        return nil;
    _socket = socket(peer.ss_family, SOCK_DGRAM, 0);
    if (_socket < 0)
        return nil;
    int buffer = 4 * 1024 * 1024;
    setsockopt(_socket, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer));
    if (bind(_socket, (struct sockaddr *)&local, localLength) ||
        connect(_socket, (struct sockaddr *)&peer, peerLength) || fcntl(_socket, F_SETFL, O_NONBLOCK) < 0) {
        _failure = @"Adaptive video could not bind its UDP port.";
        [self close];
        return nil;
    }
    _offer = [[FCVNCAppleMediaOffer alloc] initWithWidth:width height:height];
    _receiverSSRC = _offer.receiverSSRC;
    _sendKey = [NSMutableData dataWithLength:46];
    _receiveKey = [NSMutableData dataWithLength:46];
    if (!_offer || SecRandomCopyBytes(kSecRandomDefault, 46, _sendKey.mutableBytes) != errSecSuccess ||
        SecRandomCopyBytes(kSecRandomDefault, 46, _receiveKey.mutableBytes) != errSecSuccess) {
        [self close];
        return nil;
    }
    _started = Now();
    _lastFrame = _started;
    _lastFeedback = 0;
    _lastKeyframe = 0;
    return [_offer configurationWithSendKey:_sendKey receiveKey:_receiveKey];
}
- (BOOL)acceptAnswer:(NSData *)answer {
    const uint8_t *p = answer.bytes;
    if (!_offer || answer.length < 20 || U16(p) + 2 != answer.length || U16(p + 2) != 2 || U16(p + 4) != 2)
        return NO;
    NSUInteger audio = U16(p + 10), video = U16(p + 12);
    if (U16(p + 14) || 20 + audio + video != answer.length || !video)
        return NO;
    BOOL decodingOrderNumbers = NO;
    if (![FCVNCAppleMediaOffer acceptVideoAnswer:[answer subdataWithRange:NSMakeRange(20 + audio, video)]
                                      senderSSRC:&_senderSSRC
                            decodingOrderNumbers:&decodingOrderNumbers])
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
    if (srtp_create(&_send, &policy) != srtp_err_status_ok)
        return NO;
    _offer = nil;
    [self feedback:YES];
    return YES;
}
- (void)requestRefresh {
    // A display-layout change needs a fresh picture even on an otherwise idle
    // desktop. Do not wait for remote pointer damage to wake screen capture.
    _lastKeyframe = 0;
    [self feedback:YES];
}
- (void)feedback:(BOOL)keyframe {
    if (!_send || _socket < 0)
        return;
    double now = Now();
    if (keyframe && now - _lastKeyframe < .5)
        return;
    uint8_t packet[128] = {0x80, 201, 0, 1};
    W32(packet + 4, _receiverSSRC);
    // Compound RTCP includes the required CNAME. Apple's screen receiver also
    // supports the legacy FIR when AVPF feedback was not negotiated.
    packet[8] = 0x81;
    packet[9] = 202;
    W16(packet + 10, 4);
    W32(packet + 12, _receiverSSRC);
    packet[16] = 1;
    packet[17] = 7;
    memcpy(packet + 18, "Farcast", 7);
    int length = 28;
    if (keyframe) {
        packet[28] = 0x80;
        packet[29] = 192;
        W16(packet + 30, 1);
        W32(packet + 32, _receiverSSRC);
        length = 36;
        _lastKeyframe = now;
    }
    if (srtp_protect_rtcp(_send, packet, &length) == srtp_err_status_ok)
        send(_socket, packet, length, 0);
    _lastFeedback = now;
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
        uint8_t packet[65536];
        ssize_t count = recv(_socket, packet, sizeof(packet), 0);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        _datagrams++;
        if (count < 12 || (packet[0] >> 6) != 2) {
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
            _rtcpPackets++;
            continue;
        }
        if (length < 12 || (packet[1] & 127) != 100)
            continue;
        _authenticatedPackets++;
        uint16_t sequence = U16(packet + 2);
        if (!_sequenced) {
            _nextSequence = sequence;
            _sequenced = YES;
        }
        int16_t distance = (int16_t)(sequence - _nextSequence);
        if (distance < 0)
            continue;
        if (distance >= 128) {
            [_reorder removeAllObjects];
            [_hevc reset];
            _nextSequence = sequence;
            _waitingForIDR = YES;
            [self feedback:YES];
        }
        _reorder[@(sequence)] = [NSData dataWithBytes:packet length:length];
        [self drainPackets];
    }
    double now = Now();
    if (_reorder.count && _gapSince && now - _gapSince > .025) {
        // A small reorder window bounds latency and memory. Missing references
        // recover at an IDR rather than presenting corrupted dependent pictures.
        uint16_t nearest = _nextSequence;
        unsigned distance = UINT16_MAX;
        for (NSNumber *key in _reorder) {
            unsigned d = (uint16_t)(key.unsignedShortValue - _nextSequence);
            if (d < distance) {
                nearest = key.unsignedShortValue;
                distance = d;
            }
        }
        _nextSequence = nearest;
        _waitingForIDR = YES;
        _accessUnit = nil;
        [self feedback:YES];
        [self drainPackets];
    }
    if (!_receivedFrame && now - _lastKeyframe > .5)
        [self feedback:YES];
    else if (now - _lastFeedback > 1)
        [self feedback:NO];
    @synchronized(self) {
        if (_pendingPixels) {
            NSData *pixels = _pendingPixels;
            _pendingPixels = nil;
            if (self.onFrame)
                self.onFrame(pixels, _pendingWidth, _pendingHeight, _pendingStride);
            _receivedFrame = YES;
            _lastFrame = now;
        }
        if (_decodeFailed) {
            _decodeFailed = NO;
            _waitingForIDR = YES;
            [self feedback:YES];
        }
    }
    if (!_receivedFrame && now - _started > 8)
        _failure = [NSString
            stringWithFormat:
                @"Adaptive video: %lu datagrams, %lu authenticated video, %lu control, %lu NALs, %lu marked, types "
                @"%llx, parameters %lu/%lu/%lu, format %d, decode %d, authentication %d, no decoded frame.",
                (unsigned long)_datagrams, (unsigned long)_authenticatedPackets, (unsigned long)_rtcpPackets,
                (unsigned long)_nalCount, (unsigned long)_markerNALs, (unsigned long long)_nalTypes,
                (unsigned long)_vps.length, (unsigned long)_sps.length, (unsigned long)_pps.length, (int)_formatStatus,
                (int)_decodeStatus, _lastAuthenticationError];
    if (_receivedFrame && now - _lastFrame > 8)
        [self feedback:YES];
}
- (void)drainPackets {
    NSData *packet;
    while ((packet = _reorder[@(_nextSequence)])) {
        [_reorder removeObjectForKey:@(_nextSequence)];
        _nextSequence++;
        [_hevc consumeRTP:packet];
        if (_hevc.lostReference) {
            _waitingForIDR = YES;
            _accessUnit = nil;
            [self feedback:YES];
            [_hevc reset];
        }
    }
    _gapSince = _reorder.count ? (_gapSince ?: Now()) : 0;
}
- (BOOL)prepareDecoder {
    if (_decoder)
        return YES;
    if (!_vps || !_sps || !_pps)
        return NO;
    if (_format) {
        CFRelease(_format);
        _format = NULL;
    }
    const uint8_t *sets[] = {_vps.bytes, _sps.bytes, _pps.bytes};
    size_t sizes[] = {_vps.length, _sps.length, _pps.length};
    _formatStatus =
        CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, 3, sets, sizes, 4, NULL, &_format);
    if (_formatStatus)
        return NO;
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(_format);
    if (dimensions.width <= 0 || dimensions.height <= 0 || dimensions.width > 3840 || dimensions.height > 2160)
        return NO;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey : @YES
    };
    NSDictionary *specification = @{(id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder : @YES};
    VTDecompressionOutputCallbackRecord callback = {Decoded, (__bridge void *)self};
    OSStatus status =
        VTDecompressionSessionCreate(kCFAllocatorDefault, _format, (__bridge CFDictionaryRef)specification,
                                     (__bridge CFDictionaryRef)attributes, &callback, &_decoder);
    if (status) {
        _failure = @"Hardware HEVC decoding is unavailable for this stream.";
        return NO;
    }
    VTSessionSetProperty(_decoder, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    return YES;
}
- (void)nal:(NSData *)nal timestamp:(uint32_t)timestamp marker:(BOOL)marker {
    if (nal.length < 2 || nal.length > 8 * 1024 * 1024)
        return;
    _nalCount++;
    unsigned type = (((const uint8_t *)nal.bytes)[0] >> 1) & 63;
    _nalTypes |= UINT64_C(1) << type;
    if (marker)
        _markerNALs++;
    if (type == 32 || type == 33 || type == 34) {
        if (nal.length > 65535)
            return;
        NSData *previous = type == 32 ? _vps : type == 33 ? _sps : _pps;
        if (![previous isEqualToData:nal]) {
            [self retireDecoder];
            _waitingForIDR = YES;
            _accessUnit = nil;
            if (type == 32)
                _vps = nal;
            else if (type == 33)
                _sps = nal;
            else
                _pps = nal;
        }
        return;
    }
    if (type > 31)
        return;
    BOOL randomAccess = type >= 16 && type <= 21;
    if (_waitingForIDR && !randomAccess)
        return;
    if (!_accessUnit || _timestamp != timestamp) {
        _accessUnit = [NSMutableData data];
        _timestamp = timestamp;
    }
    if (_accessUnit.length + nal.length + 4 > 8 * 1024 * 1024) {
        _accessUnit = nil;
        _waitingForIDR = YES;
        return;
    }
    uint8_t size[4];
    W32(size, (uint32_t)nal.length);
    [_accessUnit appendBytes:size length:4];
    [_accessUnit appendData:nal];
    if (!marker)
        return;
    if (![self prepareDecoder]) {
        _accessUnit = nil;
        return;
    }
    _waitingForIDR = NO;
    CMBlockBufferRef block = NULL;
    CMSampleBufferRef sample = NULL;
    size_t length = _accessUnit.length;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, length, kCFAllocatorDefault, NULL,
                                                         0, length, 0, &block);
    if (!status)
        status = CMBlockBufferReplaceDataBytes(_accessUnit.bytes, block, 0, length);
    if (!status)
        status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _format, 1, 0, NULL, 1, &length, &sample);
    if (!status)
        status = VTDecompressionSessionDecodeFrame(_decoder, sample, 0, NULL, NULL);
    if (_decoder)
        VTDecompressionSessionWaitForAsynchronousFrames(_decoder);
    if (sample)
        CFRelease(sample);
    if (block)
        CFRelease(block);
    _accessUnit = nil;
    _decodeStatus = status;
    if (status) {
        _waitingForIDR = YES;
        [self feedback:YES];
    }
}
- (void)decoded:(CVImageBufferRef)image status:(OSStatus)status {
    if (status || !image) {
        @synchronized(self) {
            _decodeFailed = YES;
        }
        return;
    }
    if (CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_32BGRA || CVPixelBufferIsPlanar(image))
        return;
    NSUInteger width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image),
               stride = CVPixelBufferGetBytesPerRow(image);
    if (!width || !height || width > 3840 || height > 2160 || stride < width * 4 || stride > 65536)
        return;
    if (CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly))
        return;
    NSData *pixels = [NSData dataWithBytes:CVPixelBufferGetBaseAddress(image) length:stride * height];
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    @synchronized(self) {
        _pendingPixels = pixels;
        _pendingWidth = width;
        _pendingHeight = height;
        _pendingStride = stride;
    }
}
@end
