#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Independent bounded media negotiation; no private Apple framework dependency.
@interface FCVNCAppleMediaOffer : NSObject
@property(nonatomic, readonly) NSData *audio;
@property(nonatomic, readonly) NSData *video;
@property(nonatomic, readonly) uint32_t receiverSSRC;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height;
- (nullable NSData *)configurationWithSendKey:(NSData *)sendKey receiveKey:(NSData *)receiveKey;
// Answer is a binary plist with a zlib-compressed protobuf. Only the supported
// single-tile SDR HEVC 4:2:0 intersection is accepted.
+ (BOOL)acceptVideoAnswer:(NSData *)answer senderSSRC:(uint32_t *)ssrc;
+ (BOOL)acceptVideoAnswer:(NSData *)answer senderSSRC:(uint32_t *)ssrc decodingOrderNumbers:(BOOL *)enabled;
+ (BOOL)acceptVideoAnswer:(NSData *)answer
               senderSSRC:(uint32_t *)ssrc
     decodingOrderNumbers:(BOOL *)enabled
        longTermReference:(BOOL *)longTermReference
            allowFeedback:(BOOL *)allowFeedback;
@end
NS_ASSUME_NONNULL_END
