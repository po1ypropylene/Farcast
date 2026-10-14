#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface FCSSHClient : NSObject
// Set before connecting. Only TCP dialing changes; host-key trust stays scoped to
// the original host/port. A configured tunnel never falls back to direct dialing.
@property(nonatomic) NSInteger tunnelPort;
@property(nonatomic, copy, nullable) NSString *tunnelToken;
@property(nonatomic, copy) void (^onStatus)(NSString *state, NSString *message);
@property(nonatomic, copy) void (^onData)(NSData *data);
// Delivered on the SSH worker before connected, and when a shell ends but SFTP remains available.
@property(nonatomic, copy, nullable) void (^onTerminalAvailability)(BOOL available);
@property(nonatomic, copy, nullable) void (^onFileAvailability)(BOOL available);
// Set before connect; rules are metadata only. All listeners/channels live on the SSH worker.
@property(nonatomic, copy) NSArray<NSDictionary *> *forwardingRules;
@property(nonatomic, copy, nullable) void (^onForwarding)
    (NSString *ruleID, NSString *state, NSInteger port, NSInteger connections, NSString *message);
- (void)startForwarding:(NSString *)ruleID;
- (void)stopForwarding:(NSString *)ruleID;
// Queued, bounded runtime changes. Replacement waits for the old listener/flows to drain.
- (BOOL)updateForwarding:(NSDictionary *)configuration start:(BOOL)start;
- (BOOL)removeForwarding:(NSString *)ruleID;
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
// Pre-UI packaging check: production listener code, owned loopback sockets only.
+ (BOOL)verifyForwardingListener;
@end
NS_ASSUME_NONNULL_END
