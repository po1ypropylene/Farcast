#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Apple-specific wire protocol. All methods run on the owning VNC worker.
@interface FCVNCAppleSession : NSObject
@property(nonatomic, copy) BOOL (^readTransport)(void *bytes, NSUInteger count);
@property(nonatomic, copy) BOOL (^writeTransport)(const void *bytes, NSUInteger count);
@property(nonatomic, copy) BOOL (^approveIdentity)(NSString *fingerprint, NSString *details);
@property(nonatomic, copy) BOOL (^isCancelled)(void);
@property(nonatomic, copy, readonly) NSString *failure;
@property(nonatomic, readonly) BOOL authenticationRejected;
@property(nonatomic, readonly) BOOL encrypted;
@property(nonatomic, readonly) BOOL hasBufferedBytes;
@property(nonatomic, readonly) BOOL desktopLoginRequested;
- (BOOL)selectDesktopWithServerInfo:(NSData *)info username:(NSString *)username password:(NSString *)password;
- (BOOL)authenticateUsername:(NSString *)username password:(NSString *)password;
- (BOOL)bootstrapWidth:(NSUInteger)width height:(NSUInteger)height retina:(BOOL)retina;
- (BOOL)read:(void *)bytes count:(NSUInteger)count;
- (BOOL)write:(const void *)bytes count:(NSUInteger)count;
- (BOOL)writeInput:(NSData *)event;
- (BOOL)rekey:(NSData *)payload;
+ (nullable NSData *)displayWidth:(NSUInteger)width height:(NSUInteger)height retina:(BOOL)retina;
@end
NS_ASSUME_NONNULL_END
