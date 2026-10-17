#import "RDPClipboard.h"
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface FCRDPClient : NSObject
// Initial geometry only; one connection owns all monitors. Empty retains legacy behavior.
@property(nonatomic, copy) NSArray<NSDictionary *> *monitorDefinitions;
@property(nonatomic, copy, nullable) void (^onDesktopSize)(NSInteger width, NSInteger height);
@property(nonatomic, copy, nullable) void (^onMonitorLayout)(NSArray<NSDictionary *> *monitors);
@property(nonatomic, copy, nullable) void (^onDisplayAvailability)(BOOL available);
@property(nonatomic, copy, nullable) void (^onResizeResult)(NSInteger requestID, NSString *result);
// Set before connect; zero preserves the direct transport.
@property(nonatomic, copy) NSArray<NSDictionary *> *redirectedFolders;
@property(nonatomic) NSInteger tunnelPort;
@property(nonatomic, copy, nullable) NSString *tunnelToken;
@property(nonatomic, copy) void (^onStatus)(NSString *state, NSString *message);
// Called on the worker only after native handles and channels have retired.
@property(nonatomic, copy, nullable) void (^onStopped)(BOOL retryable);
// Worker progress, independent of incoming frames (an idle desktop is healthy).
@property(nonatomic, readonly) BOOL responsive;
- (void)interruptStalledConnection;
@property(nonatomic, copy) void (^onFrame)(NSData *pixels, NSInteger width, NSInteger height, NSInteger stride);
@property(nonatomic, copy) BOOL (^onTrust)(NSString *fingerprint, NSString *details);
@property(nonatomic, copy) void (^onClipboard)(NSString *text);
@property(nonatomic, copy) void (^onClipboardBatch)(FCRDPClipboardFileBatch *batch);
@property(nonatomic, copy) void (^onClipboardFiles)(NSArray<NSURL *> *files);
@property(nonatomic, copy) void (^onClipboardChange)(void);
@property(nonatomic, copy) void (^onClipboardProgress)(NSString *message);
@property(nonatomic, copy) void (^onCursor)
    (NSData *pixels, NSInteger width, NSInteger height, NSInteger hotX, NSInteger hotY);
- (void)connectHost:(NSString *)host
               port:(NSInteger)port
           username:(NSString *)username
             domain:(NSString *)domain
           password:(NSString *)password
              width:(NSInteger)width
             height:(NSInteger)height
              scale:(NSInteger)scale
          clipboard:(BOOL)clipboard
      audioPlayback:(BOOL)audioPlayback;
- (void)resizeWidth:(NSInteger)width height:(NSInteger)height scale:(NSInteger)scale;
- (void)resizeWidth:(NSInteger)width height:(NSInteger)height scale:(NSInteger)scale requestID:(NSInteger)requestID;
- (void)cancelResize;
- (void)sendScanCode:(NSInteger)code pressed:(BOOL)pressed extended:(BOOL)extended;
- (void)sendUnicode:(NSInteger)code pressed:(BOOL)pressed;
- (void)sendPointerFlags:(NSInteger)flags x:(NSInteger)x y:(NSInteger)y;
- (void)setClipboardText:(NSString *)text;
- (void)setClipboardFiles:(NSArray<NSURL *> *)files;
- (void)setClipboardActive:(BOOL)active;
- (void)sendControlAltDelete;
- (void)disconnect;
// Asynchronous worker drain for app termination; never blocks the main thread.
+ (void)whenAllDisconnected:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
