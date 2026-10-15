#import <Foundation/Foundation.h>
typedef struct S_IRP IRP;
typedef struct rdp_settings rdpSettings;
@interface FCRDPDrive : NSObject
- (instancetype)initWithURL:(NSURL *)url readOnly:(BOOL)readOnly;
- (void)processIRP:(IRP *)irp;
// Thread-safe: stop accepting queued work before draining the worker queue.
- (void)cancel;
// Worker-only: retire handles and scopes after queued completions have drained.
- (void)shutdown;
@end
@interface FCRDPDriveManager : NSObject
+ (void)registerProvider;
- (BOOL)configure:(NSArray<NSDictionary *> *)folders settings:(rdpSettings *)settings;
- (void)close;
@end
