#import "../../../Farcast/Native/VNC/VNCAppleMediaOffer.h"
#import "../../../Farcast/Native/VNC/VNCAppleVideo.h"
#import <VideoToolbox/VideoToolbox.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <srtp2/srtp.h>
#import <unistd.h>
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
        Require(p[0] == 0x1c && p[1] == 0 && R16(p + 2) + 4 == configuration.length && p[6] == 5,
                "offer framing and cursor omission request");
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
        srtp_dealloc(feedbackCrypto);
        __block unsigned frames = 0;
        video.onFrame = ^(NSData *pixels, NSInteger width, NSInteger height, NSInteger stride) {
          Require(width == 640 && height == 480 && pixels.length == stride * height, "hardware decoded geometry");
          const uint8_t *rgb = (const uint8_t *)pixels.bytes + 100 * stride + 100 * 4;
          Require(abs(rgb[0] - 30) < 15 && abs(rgb[1] - 100) < 15 && abs(rgb[2] - 200) < 15, "decoded synthetic color");
          frames++;
        };
        struct sockaddr_in destination = server;
        destination.sin_addr = clientAddress.sin_addr;
        NSArray *nals = Frame();
        unsigned sequence = 65530;
        NSMutableArray<NSData *> *packets = [NSMutableArray array];
        for (NSUInteger i = 0; i < nals.count; i++) {
            NSData *raw = RTP(nals[i], sequence++, i + 1 == nals.count, sender);
            NSMutableData *protected = [NSMutableData dataWithLength:raw.length + 64];
            memcpy(protected.mutableBytes, raw.bytes, raw.length);
            int length = (int)raw.length;
            Require(srtp_protect(crypto, protected.mutableBytes, &length) == srtp_err_status_ok, "protect media");
          protected
            .length = length;
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
        }
        for (unsigned i = 0; i < 100 && !frames; i++) {
            usleep(10000);
            [video pump];
        }
        Require(frames == 1 && video.receivedFrame && !video.failure, "SRTP to hardware HEVC to BGRA");
        for (NSData *packet in packets)
            sendto(udp, packet.bytes, packet.length, 0, (struct sockaddr *)&destination, sizeof(destination));
        [video pump];
        Require(frames == 1, "replay rejected");
        [video close];
        srtp_dealloc(crypto);
        close(udp);
        close(accepted);
        close(tcp);
        close(listener);
        puts("PASS Apple HEVC framing, loss, rollover, authenticated UDP, reordering, replay rejection and hardware "
             "decode");
    }
}
