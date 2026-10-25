#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Worker-owned RFC 3550 reception statistics for one authenticated RTP source.
@interface FCVNCAppleFeedback : NSObject
- (instancetype)initWithReceiver:(uint32_t)receiver sender:(uint32_t)sender;
- (void)receiveSequence:(uint16_t)sequence timestamp:(uint32_t)timestamp atTime:(double)now;
- (void)receiveControl:(NSData *)packet atTime:(double)now;
- (NSMutableData *)reportAtTime:(double)now;
@end
NS_ASSUME_NONNULL_END
