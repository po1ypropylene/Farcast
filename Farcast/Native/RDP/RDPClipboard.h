#import <Foundation/Foundation.h>

@interface FCRDPClipboardFileBatch : NSObject
- (instancetype)initWithRoot:(NSURL *)root files:(NSArray<NSURL *> *)files;
@property(nonatomic, readonly) NSArray<NSURL *> *files;
// A pasteboard consumer can wait without involving the main actor. The RDP
// worker completes or cancels this condition independently of UI callbacks.
- (BOOL)waitUntilReadyWithTimeout:(NSTimeInterval)timeout NS_SWIFT_NAME(waitUntilReady(timeout:));
@end

// All methods and callbacks run on the owning RDP worker, never the main thread.
// The pasteboard bridge supplies only explicitly shared file URLs.
typedef struct s_cliprdr_client_context CliprdrClientContext;
@interface FCRDPClipboard : NSObject
@property(nonatomic, copy) void (^onText)(NSString *text);
@property(nonatomic, copy) void (^onBatch)(FCRDPClipboardFileBatch *batch);
@property(nonatomic, copy) void (^onFiles)(NSArray<NSURL *> *files);
@property(nonatomic, copy) void (^onRemoteChange)(void);
@property(nonatomic, copy) void (^onProgress)(NSString *message);
- (void)attach:(CliprdrClientContext *)channel;
- (void)detach;
- (void)setActive:(BOOL)active;
- (void)setText:(NSString *)text;
- (void)setFiles:(NSArray<NSURL *> *)files;
- (void)tick;
@end
