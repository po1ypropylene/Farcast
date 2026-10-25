#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Runs on the VNC protocol worker. UDP is bound to the authenticated TCP peer.
@interface FCVNCAppleVideo : NSObject
@property(nonatomic, copy, nullable) void (^onFrame)(CVPixelBufferRef);
// Poll with the TCP socket on the same worker; -1 before authenticated media.
@property(nonatomic, readonly) int socketDescriptor;
@property(nonatomic, readonly) BOOL receivedFrame;
@property(nonatomic, readonly, nullable) NSString *failure;
- (instancetype)initWithTCPDescriptor:(int)tcp;
// Payload includes the 2-byte size prefix of encoding 0x3f2.
- (nullable NSData *)configure:(NSData *)request width:(NSUInteger)width height:(NSUInteger)height;
- (BOOL)acceptAnswer:(NSData *)answer;
- (void)pump;
- (void)requestRefresh;
- (void)close;
@end
// Statelessly framed, bounded Apple HEVC depacketizer. Exported only to native
// integration tests; output is a complete NAL without DONL.
@interface FCVNCAppleHEVC : NSObject
@property(nonatomic) BOOL decodingOrderNumbers;
@property(nonatomic, copy, nullable) void (^onNAL)(NSData *nal, uint32_t timestamp, BOOL marker);
// Borrowed spans are valid only during this synchronous worker callback.
// Single NALs/APs borrow packet storage; fragmented NALs borrow reassembly storage.
@property(nonatomic, copy, nullable) void (^onNALParts)
    (const void *header, NSUInteger headerLength, const void *payload, NSUInteger payloadLength, uint32_t timestamp,
     BOOL marker);
@property(nonatomic, readonly) BOOL lostReference;
@property(nonatomic, readonly) BOOL markedReference;
@property(nonatomic, readonly) uint32_t referenceIdentifier;
- (void)consumeRTP:(NSData *)packet;
- (void)consumeRTPBytes:(const void *)bytes length:(NSUInteger)length;
- (void)reset;
@end
NS_ASSUME_NONNULL_END
