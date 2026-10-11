#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface FCSSHClient : NSObject
@property(nonatomic, copy) void (^onStatus)(NSString *state, NSString *message);
@property(nonatomic, copy) void (^onData)(NSData *data);
// Delivered on the SSH worker before connected, and when a shell ends but SFTP remains available.
@property(nonatomic, copy, nullable) void (^onTerminalAvailability)(BOOL available);
// Delivered on the SSH worker before failed when the server rejects credentials.
@property(nonatomic, copy, nullable) void (^onAuthenticationRejected)(void);
@property(nonatomic, copy) BOOL (^onTrust)(NSString *fingerprint, NSString *details);
@property(nonatomic, copy) NSString *_Nullable (^onPrompt)(NSString *prompt, BOOL echo);
- (void)connectHost:(NSString *)host
               port:(NSInteger)port
           username:(NSString *)username
           password:(NSString *)password
         privateKey:(nullable NSData *)key
     authentication:(NSString *)authentication;
// Results and progress are delivered on the SSH worker, never the UI thread.
@property(nonatomic, copy, nullable) void (^onFiles)
    (NSString *requestID, NSDictionary *result, NSString *_Nullable error);
@property(nonatomic, copy, nullable) void (^onFileProgress)
    (NSString *requestID, unsigned long long bytes, unsigned long long total);
// Conflict callbacks run on the worker. Resolve the unique token: 0 stops, 1 overwrites.
@property(nonatomic, copy, nullable) void (^onFileConflict)(NSString *token, NSString *name);
- (void)resolveFileConflict:(NSString *)token overwrite:(BOOL)overwrite;
- (void)listDirectory:(NSString *)path requestID:(NSString *)requestID;
- (void)transferLocalPath:(NSString *)localPath
               remotePath:(NSString *)remotePath
                   upload:(BOOL)upload
                requestID:(NSString *)requestID;
// kind: uploadTree, downloadTree, copyRemote, mkdir, rename, removeTree.
- (void)fileOperation:(NSString *)kind
               source:(NSString *)source
          destination:(NSString *)destination
                 move:(BOOL)move
            requestID:(NSString *)requestID;
- (void)sendData:(NSData *)data;
// Thread-safe scheduling hint; native handles remain exclusively on the worker.
- (void)setTerminalVisible:(BOOL)visible;
- (void)resizeColumns:(NSInteger)columns rows:(NSInteger)rows;
- (void)cancelFiles;
- (void)disconnect;
// Asynchronous worker drain for app termination; never blocks the main thread.
+ (void)whenAllDisconnected:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
