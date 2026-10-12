#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Independently implemented RFB worker. Callbacks run on its protocol queue.
@interface FCVNCClient : NSObject
@property(nonatomic) NSInteger tunnelPort;
@property(nonatomic, copy, nullable) NSString *tunnelToken;
@property(nonatomic, copy, nullable) void (^onStatus)(NSString *state, NSString *message);
@property(nonatomic, copy, nullable) void (^onFrame)
    (NSData *pixels, NSInteger width, NSInteger height, NSInteger stride);
@property(nonatomic, copy, nullable) void (^onDesktopSize)(NSInteger width, NSInteger height);
@property(nonatomic, copy, nullable) void (^onAuthenticationRejected)(void);
@property(nonatomic, copy, nullable) BOOL (^onTrust)(NSString *fingerprint, NSString *details);
@property(nonatomic, copy, nullable) void (^onTyping)(BOOL typing);
- (void)connectHost:(NSString *)host port:(NSInteger)port username:(NSString *)username password:(NSString *)password;
- (void)sendKeySym:(uint32_t)key pressed:(BOOL)pressed;
- (void)sendPointerMask:(NSInteger)mask x:(NSInteger)x y:(NSInteger)y;
// Returns NO for oversized text or controls other than newline/tab; never sends cut-text.
- (BOOL)typeText:(NSString *)text;
- (void)cancelTyping;
- (void)sendControlAltDelete;
- (void)disconnect;
+ (void)whenAllDisconnected:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
