#import "../../../Farcast/Native/VNC/VNCAppleFeedback.h"
#import "../../../Farcast/Native/VNC/VNCAppleMediaOffer.h"
#import "../../../Farcast/Native/VNC/VNCAppleVideo.h"
#import <VideoToolbox/VideoToolbox.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <srtp2/srtp.h>
#import <unistd.h>
#import <zlib.h>
static void Require(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL %s\n", message);
        exit(1);
    }
}
static void W16(uint8_t *p, unsigned n) {
    p[0] = n >> 8;
    p[1] = n;
}
static void W32(uint8_t *p, uint32_t n) {
    W16(p, n >> 16);
    W16(p + 2, n);
}
static unsigned R16(const uint8_t *p) { return p[0] * 256 + p[1]; }
static const uint8_t *Control(const uint8_t *p, NSUInteger length, unsigned type) {
    for (NSUInteger offset = 0; length - offset >= 4;) {
        NSUInteger size = 4 * (1 + R16(p + offset + 2));
        if (size > length - offset)
            return NULL;
        if (p[offset + 1] == type)
            return p + offset;
        offset += size;
    }
    return NULL;
}
static uint32_t R32(const uint8_t *p) { return R16(p) << 16 | R16(p + 2); }
static NSData *Capabilities(unsigned feedback, unsigned ltr, unsigned interleaving) {
    // Independently framed minimal synthetic answer; no production serializer.
    uint8_t protobuf[] = {0x2a, 16, 0x08, 9,   0x10, feedback, 0x1a, 2, 0x08, 100,
                          0x30, 1,  0x38, ltr, 0x40, 1,        0x48, 1, 0x70, interleaving};
    protobuf[1] = sizeof(protobuf) - 2;
    uLongf length = compressBound(sizeof(protobuf));
    NSMutableData *compressed = [NSMutableData dataWithLength:length];
    Require(compress2(compressed.mutableBytes, &length, protobuf, sizeof(protobuf), Z_DEFAULT_COMPRESSION) == Z_OK,
            "compress synthetic capability answer");
    compressed.length = length;
    return [NSPropertyListSerialization dataWithPropertyList:@{@"avcMediaStreamNegotiatorMediaBlob" : compressed}
                                                      format:NSPropertyListBinaryFormat_v1_0
                                                     options:0
                                                       error:nil];
}
static void Negotiation(void) {
    BOOL feedback, ltr, don;
    uint32_t sender;
    Require([FCVNCAppleMediaOffer acceptVideoAnswer:Capabilities(0, 0, 0)
                                         senderSSRC:&sender
                               decodingOrderNumbers:&don
                                  longTermReference:&ltr
                                      allowFeedback:&feedback] &&
                !feedback && !ltr && !don,
            "legacy answer does not silently enable NACK or LTR");
    Require([FCVNCAppleMediaOffer acceptVideoAnswer:Capabilities(1, 1, 1)
                                         senderSSRC:&sender
                               decodingOrderNumbers:&don
                                  longTermReference:&ltr
                                      allowFeedback:&feedback] &&
                feedback && ltr && don,
            "feedback, LTR and DON require the accepted intersection");
    for (NSData *bad in @[ Capabilities(2, 0, 0), Capabilities(0, 2, 0), Capabilities(0, 0, 2) ])
        Require(![FCVNCAppleMediaOffer acceptVideoAnswer:bad
                                              senderSSRC:&sender
                                    decodingOrderNumbers:&don
                                       longTermReference:&ltr
                                           allowFeedback:&feedback],
                "invalid capability rejected");
}
static void Reports(void) {
    FCVNCAppleFeedback *stats = [[FCVNCAppleFeedback alloc] initWithReceiver:7 sender:9];
    Require([stats reportAtTime:1].length == 28, "empty RR before media");
    [stats receiveSequence:65534 timestamp:90000 atTime:1];
    [stats receiveSequence:0 timestamp:93000 atTime:1.04];
    NSData *report = [stats reportAtTime:1.1];
    const uint8_t *p = report.bytes;
    Require(report.length == 52 && p[0] == 0x81 && R32(p + 8) == 9 && p[12] == 85 && p[15] == 1 &&
                R32(p + 16) == 65536 && R32(p + 20) > 0,
            "RR loss fraction, cumulative loss, sequence rollover and jitter");
    [stats receiveSequence:65535 timestamp:91500 atTime:1.05];
    uint8_t sr[28] = {0x80, 200, 0, 6};
    W32(sr + 4, 9);
    W32(sr + 8, 0x12345678);
    W32(sr + 12, 0x9abcdef0);
    [stats receiveControl:[NSData dataWithBytes:sr length:sizeof(sr)] atTime:2];
    report = [stats reportAtTime:2.25];
    p = report.bytes;
    Require(p[12] == 0 && p[15] == 0 && R32(p + 24) == 0x56789abc && R32(p + 28) == 16384,
            "late repair reduces loss, SR middle NTP and delay are reported");
    sr[4] = 1;
    [stats receiveControl:[NSData dataWithBytes:sr length:sizeof(sr)] atTime:3];
    uint8_t bad[4] = {0x80, 200, 255, 255};
    [stats receiveControl:[NSData dataWithBytes:bad length:4] atTime:3];
    report = [stats reportAtTime:3];
    p = report.bytes;
    Require(R32(p + 24) == 0x56789abc, "foreign and truncated sender reports ignored");
}
static NSData *RTP(NSData *payload, unsigned sequence, BOOL marker, uint32_t ssrc) {
    NSMutableData *packet = [NSMutableData dataWithLength:12];
    uint8_t *p = packet.mutableBytes;
    p[0] = 128;
    p[1] = 100 | (marker ? 128 : 0);
    W16(p + 2, sequence);
    W32(p + 4, 90000);
    W32(p + 8, ssrc);
    [packet appendData:payload];
    return packet;
}
static NSData *Marked(NSData *packet) {
    NSMutableData *result = [packet mutableCopy];
    ((uint8_t *)result.mutableBytes)[0] |= 0x10;
    uint8_t extension[4] = {0x80, 0x10, 0, 0};
    [result replaceBytesInRange:NSMakeRange(12, 0) withBytes:extension length:4];
    return result;
}
static NSData *Single(NSData *nal) {
    NSMutableData *payload = [NSMutableData dataWithLength:4];
    memcpy(payload.mutableBytes, nal.bytes, 2);
    [payload appendBytes:(const uint8_t *)nal.bytes + 2 length:nal.length - 2];
    return payload;
}
static void Encoded(void *context, void *source, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    Require(!status && sample, "hardware HEVC encode");
    NSMutableArray *nals = (__bridge NSMutableArray *)context;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    size_t count = 0;
    Require(!CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, NULL, NULL, &count, NULL),
            "parameter count");
    for (size_t i = 0; i < count; i++) {
        const uint8_t *p;
        size_t size;
        Require(!CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &p, &size, NULL, NULL),
                "parameter sets");
        [nals addObject:[NSData dataWithBytes:p length:size]];
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t length = CMBlockBufferGetDataLength(block);
    NSMutableData *data = [NSMutableData dataWithLength:length];
    Require(!CMBlockBufferCopyDataBytes(block, 0, length, data.mutableBytes), "encoded bytes");
    const uint8_t *p = data.bytes;
    for (size_t offset = 0; offset < length;) {
        Require(length - offset >= 4, "NAL length prefix");
        size_t size = (uint32_t)p[offset] << 24 | (uint32_t)p[offset + 1] << 16 | p[offset + 2] << 8 | p[offset + 3];
        offset += 4;
        Require(size >= 2 && size <= length - offset, "NAL extent");
        [nals addObject:[NSData dataWithBytes:p + offset length:size]];
        offset += size;
    }
}
static NSArray<NSData *> *Frame(void) {
    NSMutableArray *nals = [NSMutableArray array];
    VTCompressionSessionRef encoder = NULL;
    NSDictionary *spec = @{(id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder : @YES};
    Require(!VTCompressionSessionCreate(NULL, 640, 480, kCMVideoCodecType_HEVC, (__bridge CFDictionaryRef)spec, NULL,
                                        NULL, Encoded, (__bridge void *)nals, &encoder),
            "create hardware encoder");
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
    CVPixelBufferRef pixels = NULL;
    Require(!CVPixelBufferCreate(
                NULL, 640, 480, kCVPixelFormatType_32BGRA,
                (__bridge CFDictionaryRef)
                    @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}},
                &pixels),
            "synthetic pixels");
    CVPixelBufferLockBaseAddress(pixels, 0);
    size_t stride = CVPixelBufferGetBytesPerRow(pixels);
    for (size_t y = 0; y < 480; y++) {
        uint8_t *row = (uint8_t *)CVPixelBufferGetBaseAddress(pixels) + y * stride;
        for (size_t x = 0; x < 640; x++) {
            row[x * 4] = 30;
            row[x * 4 + 1] = 100;
            row[x * 4 + 2] = 200;
            row[x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    Require(!VTCompressionSessionEncodeFrame(encoder, pixels, CMTimeMake(0, 60), CMTimeMake(1, 60), NULL, NULL, NULL),
            "encode synthetic frame");
    Require(!VTCompressionSessionCompleteFrames(encoder, kCMTimeInvalid), "finish encode");
    CVPixelBufferRelease(pixels);
    VTCompressionSessionInvalidate(encoder);
    CFRelease(encoder);
    Require(nals.count >= 4, "HEVC frame and parameter sets");
    return nals;
}
static void Depacketizer(void) {
    FCVNCAppleHEVC *parser = [FCVNCAppleHEVC new];
    parser.decodingOrderNumbers = YES;
    NSMutableArray *received = [NSMutableArray array];
    parser.onNAL = ^(NSData *nal, uint32_t timestamp, BOOL marker) {
      [received addObject:nal];
    };
    uint8_t nal[] = {0x26, 1, 1, 2, 3, 4, 5};
    NSData *original = [NSData dataWithBytes:nal length:sizeof(nal)];
    [parser consumeRTP:RTP(Single(original), 65535, YES, 5)];
    Require([received.lastObject isEqual:original], "single NAL strips DONL");
    NSMutableData *markedPayload = [Single(original) mutableCopy];
    W16((uint8_t *)markedPayload.mutableBytes + 2, 65535);
    [parser consumeRTP:Marked(RTP(markedPayload, 0, YES, 5))];
    Require(parser.markedReference && parser.referenceIdentifier == 65535,
            "Apple marked reference uses negotiated DON, not RTP timestamp");
    [parser reset];
    [received removeLastObject];
    uint8_t first[] = {0x62, 1, 0x93, 0, 7, 1, 2}, last[] = {0x62, 1, 0x53, 0, 7, 3, 4, 5};
    [parser consumeRTP:RTP([NSData dataWithBytes:first length:sizeof(first)], 0, NO, 5)];
    [parser consumeRTP:RTP([NSData dataWithBytes:last length:sizeof(last)], 1, YES, 5)];
    Require(received.count == 2 && [received.lastObject isEqual:original] && !parser.lostReference,
            "fragment DONL and sequence rollover");
    [parser consumeRTP:RTP([NSData dataWithBytes:first length:sizeof(first)], 2, NO, 5)];
    [parser consumeRTP:RTP([NSData dataWithBytes:last length:sizeof(last)], 4, YES, 5)];
    Require(received.count == 2 && parser.lostReference, "loss discards incomplete NAL");
    [parser reset];
    uint8_t ap[] = {0x60, 1, 0, 9, 0, 3, 0x40, 1, 9, 0, 3, 0x42, 1, 8};
    [parser consumeRTP:RTP([NSData dataWithBytes:ap length:sizeof(ap)], 5, YES, 5)];
    Require(received.count == 4, "aggregation without per-NAL DOND");
    uint8_t bad[] = {0x60, 1, 0, 9, 255, 255};
    [parser consumeRTP:RTP([NSData dataWithBytes:bad length:sizeof(bad)], 6, YES, 5)];
    Require(received.count == 4 && parser.lostReference, "malformed aggregate bounded");
    [parser reset];
    parser.decodingOrderNumbers = NO;
    uint8_t shortExtension[14] = {0x90, 100};
    [parser consumeRTP:[NSData dataWithBytes:shortExtension length:sizeof(shortExtension)]];
    Require(received.count == 4, "truncated noninterleaved RTP extension ignored");
    NSMutableData *plainAP = [[NSData dataWithBytes:ap length:sizeof(ap)] mutableCopy];
    [plainAP replaceBytesInRange:NSMakeRange(2, 2) withBytes:NULL length:0];
    [parser consumeRTP:RTP(plainAP, 7, YES, 5)];
    Require(received.count == 6 && !parser.lostReference, "noninterleaved parameter aggregate");
    NSMutableData *plainFirst = [[NSData dataWithBytes:first length:sizeof(first)] mutableCopy];
    NSMutableData *plainLast = [[NSData dataWithBytes:last length:sizeof(last)] mutableCopy];
    [plainFirst replaceBytesInRange:NSMakeRange(3, 2) withBytes:NULL length:0];
    [plainLast replaceBytesInRange:NSMakeRange(3, 2) withBytes:NULL length:0];
    [parser consumeRTP:RTP(plainFirst, 8, NO, 5)];
    [parser consumeRTP:RTP(plainLast, 9, YES, 5)];
    Require(received.count == 7 && [received.lastObject isEqual:original], "noninterleaved fragments");
}
int main(void) {
    @autoreleasepool {
        Depacketizer();
        Reports();
        Negotiation();
        struct sockaddr_in server = {.sin_len = sizeof(server), .sin_family = AF_INET};
        inet_pton(AF_INET, "127.0.0.1", &server.sin_addr);
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        Require(listener >= 0 && !bind(listener, (struct sockaddr *)&server, sizeof(server)) && !listen(listener, 1),
                "TCP fixture listener");
        socklen_t size = sizeof(server);
        getsockname(listener, (struct sockaddr *)&server, &size);
        int tcp = socket(AF_INET, SOCK_STREAM, 0);
        // Both peers use the same UDP port, as Apple's transport requires. Bind
        // this local synthetic client to an existing interface address so its
        // UDP endpoint is distinct from the fixture's loopback endpoint.
        struct ifaddrs *addresses = NULL;
        Require(!getifaddrs(&addresses), "interface inventory");
        struct sockaddr_in clientAddress = {.sin_len = sizeof(clientAddress), .sin_family = AF_INET};
        for (struct ifaddrs *a = addresses; a; a = a->ifa_next) {
            if (a->ifa_addr && a->ifa_addr->sa_family == AF_INET && (a->ifa_flags & IFF_UP) &&
                !(a->ifa_flags & IFF_LOOPBACK)) {
                clientAddress.sin_addr = ((struct sockaddr_in *)a->ifa_addr)->sin_addr;
                break;
            }
        }
        freeifaddrs(addresses);
        Require(clientAddress.sin_addr.s_addr && !bind(tcp, (struct sockaddr *)&clientAddress, sizeof(clientAddress)),
                "local fixture client address");

        Require(!connect(tcp, (struct sockaddr *)&server, sizeof(server)), "TCP fixture peer");
        int accepted = accept(listener, NULL, NULL);
        Require(accepted >= 0, "TCP fixture accept");
        int udp = socket(AF_INET, SOCK_DGRAM, 0);
        server.sin_port = 0;
        Require(!bind(udp, (struct sockaddr *)&server, sizeof(server)), "UDP fixture bind");
        getsockname(udp, (struct sockaddr *)&server, &size);
        uint8_t request[38] = {0};
        W16(request, 36);
        W16(request + 2, 1);
        W16(request + 4, 1);
        W16(request + 16, ntohs(server.sin_port));
        W32(request + 18, 1);
        FCVNCAppleVideo *video = [[FCVNCAppleVideo alloc] initWithTCPDescriptor:tcp];
        NSData *configuration = [video configure:[NSData dataWithBytes:request length:38] width:640 height:480];
        Require(configuration != nil, "media configuration");
        const uint8_t *p = configuration.bytes;
        Require(p[0] == 0x1c && p[1] == 0 && R16(p + 2) + 4 == configuration.length && p[6] == 1,
                "offer framing retains the server cursor");
        size_t audioLength = R16(p + 10), videoLength = R16(p + 12), offset = 128 + audioLength;
        NSData *offer = [configuration subdataWithRange:NSMakeRange(offset + 92, videoLength)];
        uint32_t sender;
        Require([FCVNCAppleMediaOffer acceptVideoAnswer:offer senderSSRC:&sender], "supported synthetic negotiation");
        Require(![FCVNCAppleMediaOffer acceptVideoAnswer:[NSData data] senderSSRC:&sender], "reject malformed answer");
        NSMutableData *answer = [NSMutableData dataWithLength:20];
        uint8_t *a = answer.mutableBytes;
        W16(a, 18 + videoLength);
        W16(a + 2, 2);
        W16(a + 4, 2);
        W16(a + 12, videoLength);
        [answer appendData:offer];
        Require([video acceptAnswer:answer], "accept media answer");
        srtp_policy_t policy = {0};
        srtp_crypto_policy_set_aes_cm_256_hmac_sha1_80(&policy.rtp);
        srtp_crypto_policy_set_aes_cm_256_hmac_sha1_80(&policy.rtcp);
        policy.ssrc.type = ssrc_specific;
        policy.ssrc.value = sender;
        policy.key = (uint8_t *)p + offset + 46;
        policy.window_size = 512;
        srtp_t crypto = NULL;
        Require(srtp_create(&crypto, &policy) == srtp_err_status_ok, "fixture SRTP");
        srtp_policy_t feedbackPolicy = policy;
        feedbackPolicy.key = (uint8_t *)p + offset;
        srtp_t feedbackCrypto = NULL;
        Require(srtp_create(&feedbackCrypto, &feedbackPolicy) == srtp_err_status_ok, "fixture feedback receiver");
        uint8_t feedback[512];
        ssize_t feedbackSize = recv(udp, feedback, sizeof(feedback), MSG_DONTWAIT);
        for (unsigned retry = 0; feedbackSize < 0 && retry < 30; retry++) {
            usleep(1000);
            feedbackSize = recv(udp, feedback, sizeof(feedback), MSG_DONTWAIT);
        }
        int clearFeedbackSize = (int)feedbackSize;
        srtp_err_status_t feedbackStatus =
            feedbackSize > 0 ? srtp_unprotect_rtcp(feedbackCrypto, feedback, &clearFeedbackSize) : srtp_err_status_fail;
        if (feedbackStatus)
            fprintf(stderr, "feedback bytes=%ld status=%d errno=%d\n", (long)feedbackSize, feedbackStatus, errno);
        Require(feedbackStatus == srtp_err_status_ok, "directional SRTCP feedback authentication");
        Require(clearFeedbackSize == 36 && feedback[1] == 201 && feedback[9] == 202 && feedback[29] == 192,
                "compound receiver report, CNAME and native FIR");
        __block unsigned frames = 0;
        video.onFrame = ^(CVPixelBufferRef pixels) {
          Require(CVPixelBufferGetWidth(pixels) == 640 && CVPixelBufferGetHeight(pixels) == 480 &&
                      CVPixelBufferGetIOSurface(pixels),
                  "hardware decoded IOSurface geometry");
          CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
          Require(CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
                      CVPixelBufferGetPlaneCount(pixels) == 2,
                  "native full-range NV12 decoder output");
          const uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0);
          const uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(pixels, 1);
          Require(abs(luma[100 * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) + 100] - 122) < 20 &&
                      abs(chroma[50 * CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) + 100] - 76) < 20 &&
                      abs(chroma[50 * CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) + 101] - 184) < 20,
                  "decoded synthetic YCbCr color");
          CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
          frames++;
        };
        struct sockaddr_in destination = server;
        destination.sin_addr = clientAddress.sin_addr;
        NSArray *nals = Frame();
        unsigned sequence = 65530;
        NSMutableArray<NSData *> *packets = [NSMutableArray array];
        for (NSUInteger i = 0; i < nals.count; i++) {
            NSData *raw = Marked(RTP(nals[i], sequence++, i + 1 == nals.count, sender));
            NSMutableData *protected = [NSMutableData dataWithLength:raw.length + 64];
            memcpy(protected.mutableBytes, raw.bytes, raw.length);
            int length = (int)raw.length;
            Require(srtp_protect(crypto, protected.mutableBytes, &length) == srtp_err_status_ok, "protect media");
            protected.length = length;
            [packets addObject:protected];
        }
        // A forged packet must not advance sequence state or reach the decoder.
        NSMutableData *forged = [packets[0] mutableCopy];
        ((uint8_t *)forged.mutableBytes)[forged.length - 1] ^= 1;
        sendto(udp, forged.bytes, forged.length, 0, (struct sockaddr *)&destination, sizeof(destination));
        [video pump];
        Require(frames == 0, "unauthenticated packet ignored");
        // Send one packet, then reorder the following pair within the bounded window.
        for (NSUInteger i = 0; i < packets.count; i++) {
            NSUInteger index = i == 1 && packets.count > 2 ? 2 : i == 2 ? 1 : i;
            NSData *packet = packets[index];
            Require(sendto(udp, packet.bytes, packet.length, 0, (struct sockaddr *)&destination, sizeof(destination)) ==
                        packet.length,
                    "send media");
            [video pump];
            if (i == 1 && packets.count > 2) {
                usleep(10000);
                [video pump];
                BOOL gotNACK = NO;
                for (unsigned attempt = 0; attempt < 50; attempt++) {
                    usleep(1000);
                    [video pump];
                    int size = (int)recv(udp, feedback, sizeof(feedback), MSG_DONTWAIT);
                    if (size < 0)
                        continue;
                    Require(srtp_unprotect_rtcp(feedbackCrypto, feedback, &size) == srtp_err_status_ok,
                            "authenticated retransmission request");
                    const uint8_t *nack = Control(feedback, size, 205);
                    if (nack) {
                        Require(nack[0] == 0x81 && R16(nack + 12) == 65531 && R16(nack + 14) == 0,
                                "NACK asks for the exact missing packet");
                        gotNACK = YES;
                        break;
                    }
                    Require(!Control(feedback, size, 192), "repair window does not send FIR");
                }
                Require(gotNACK, "missing packet requested before reference reset");
            }
        }
        for (unsigned i = 0; i < 100 && !frames; i++) {
            usleep(10000);
            [video pump];
        }
        Require(frames == 1 && video.receivedFrame && !video.failure, "SRTP to hardware HEVC to native NV12");
        for (NSData *packet in packets)
            sendto(udp, packet.bytes, packet.length, 0, (struct sockaddr *)&destination, sizeof(destination));
        [video pump];
        Require(frames == 1, "replay rejected");
        // Drain feedback generated before the first decode acknowledgement.
        // Faster startup FIR backoff can legitimately queue reports without LTR.
        for (;;) {
            int size = (int)recv(udp, feedback, sizeof(feedback), MSG_DONTWAIT);
            if (size < 0)
                break;
            Require(srtp_unprotect_rtcp(feedbackCrypto, feedback, &size) == srtp_err_status_ok,
                    "authenticated startup feedback");
        }
        // Lose a packet after successful display, inside the FIR throttle. A
        // dependent picture cannot recover it, and no new input arrives later.
        uint8_t dependent[] = {2, 1, 9};
        NSData *raw = RTP([NSData dataWithBytes:dependent length:3], sequence + 1, YES, sender);
        NSMutableData *lost = [NSMutableData dataWithLength:raw.length + 64];
        memcpy(lost.mutableBytes, raw.bytes, raw.length);
        int lostLength = (int)raw.length;
        Require(srtp_protect(crypto, lost.mutableBytes, &lostLength) == srtp_err_status_ok, "protect loss fixture");
        sendto(udp, lost.bytes, lostLength, 0, (struct sockaddr *)&destination, sizeof(destination));
        [video pump];
        usleep(90000);
        [video pump];
        // A new, complete-boundary picture with invalid coded data must not
        // advance the last marked-reference acknowledgement on decode failure.
        uint8_t brokenPicture[] = {2, 1, 0x89};
        NSMutableData *broken =
            [Marked(RTP([NSData dataWithBytes:brokenPicture length:3], sequence + 2, YES, sender)) mutableCopy];
        W32((uint8_t *)broken.mutableBytes + 4, 93000);
        NSMutableData *sealed = [NSMutableData dataWithLength:broken.length + 64];
        memcpy(sealed.mutableBytes, broken.bytes, broken.length);
        int brokenLength = (int)broken.length;
        Require(srtp_protect(crypto, sealed.mutableBytes, &brokenLength) == srtp_err_status_ok,
                "protect marked decode failure");
        sendto(udp, sealed.bytes, brokenLength, 0, (struct sockaddr *)&destination, sizeof(destination));
        [video pump];
        const useconds_t recoveryDelays[] = {200000, 350000, 650000};
        for (unsigned retry = 0; retry < 3; retry++) {
            usleep(recoveryDelays[retry]);
            [video pump];
            BOOL gotFIR = NO;
            for (unsigned attempt = 0; attempt < 50; attempt++) {
                usleep(1000);
                int size = (int)recv(udp, feedback, sizeof(feedback), MSG_DONTWAIT);
                if (size < 0)
                    continue;
                Require(srtp_unprotect_rtcp(feedbackCrypto, feedback, &size) == srtp_err_status_ok,
                        "authenticated recovery feedback");
                const uint8_t *rr = Control(feedback, size, 201);
                Require(rr && rr[0] == 0x81 && R32(rr + 16) >= 65530, "populated receiver report after media");
                const uint8_t *ack = Control(feedback, size, 204);
                Require(ack && R32(ack + 8) == 5 && R32(ack + 12) == 90000,
                        "LTR APP acknowledges only the last successfully decoded marked RTP timestamp");
                if (Control(feedback, size, 192))
                    gotFIR = YES;
            }
            Require(gotFIR, "post-frame loss retries authenticated FIR without input");
        }
        Require(frames == 1, "dependent frame not displayed after loss");
        // One receive burst contains three complete marked IRAP pictures. Only
        // the newest needs decoding; its retained backing must survive callbacks.
        sequence += 3;
        for (unsigned picture = 0; picture < 3; picture++) {
            for (NSUInteger i = 0; i < nals.count; i++) {
                NSMutableData *raw = [Marked(RTP(nals[i], sequence++, i + 1 == nals.count, sender)) mutableCopy];
                W32((uint8_t *)raw.mutableBytes + 4, 96000 + 3000 * picture);
                NSMutableData *sealed = [NSMutableData dataWithLength:raw.length + 64];
                memcpy(sealed.mutableBytes, raw.bytes, raw.length);
                int length = (int)raw.length;
                Require(srtp_protect(crypto, sealed.mutableBytes, &length) == srtp_err_status_ok, "seal IRAP burst");
                Require(sendto(udp, sealed.bytes, length, 0, (struct sockaddr *)&destination, sizeof(destination)) ==
                            length,
                        "send IRAP burst");
            }
        }
        for (unsigned i = 0; i < 150 && frames < 2; i++) {
            [video pump];
            usleep(10000);
        }
        Require(frames == 2, "IRAP burst decodes the latest complete picture only");
        [video requestRefresh];
        BOOL newestAcknowledged = NO;
        for (unsigned attempt = 0; attempt < 100 && !newestAcknowledged; attempt++) {
            usleep(1000);
            int length = (int)recv(udp, feedback, sizeof(feedback), MSG_DONTWAIT);
            if (length < 0)
                continue;
            Require(srtp_unprotect_rtcp(feedbackCrypto, feedback, &length) == srtp_err_status_ok,
                    "authenticate latest IRAP report");
            const uint8_t *ack = Control(feedback, length, 204);
            if (ack && R32(ack + 12) == 102000)
                newestAcknowledged = YES;
        }
        Require(newestAcknowledged, "latest queued IRAP reference, not an earlier picture, reaches hardware decode");
        [video close];
        srtp_dealloc(feedbackCrypto);
        srtp_dealloc(crypto);
        close(udp);
        close(accepted);
        close(tcp);
        close(listener);
        puts("PASS Apple HEVC framing, loss, rollover, authenticated UDP, reordering, replay rejection and hardware "
             "decode");
    }
}
