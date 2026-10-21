#pragma once
#import "SSHClient.h"
#import <libssh2.h>
#import <libssh2_sftp.h>
#import <stdatomic.h>
#import <time.h>

// All native handles remain exclusively on the original SSH worker. Categories
// organize its work; they create no clients, transports, queues or authentication.
@interface FCSSHClient () {
    atomic_bool _stopped;
    atomic_bool _filesCancelled;
    atomic_bool _terminalVisible;
    NSString *_conflictToken;
    NSInteger _conflictChoice;
    double _lastTerminalPump;
    int _terminalWaitDirections;
    NSLock *_lock;
    NSMutableData *_outgoing;
    NSData *_terminalWrite;
    int _socket;
    NSInteger _columns, _rows;
    BOOL _resizePending;
    BOOL _resizeInFlight;
    int _submittedColumns, _submittedRows;
    BOOL _inputOverflowed;
    BOOL _terminalUnavailable;
    NSString *_interactivePassword;
    BOOL _passwordResponseUsed;
    NSMutableArray<NSDictionary *> *_fileRequests;
    NSString *_activeFileRequest;
    LIBSSH2_SESSION *_workerSession;
    LIBSSH2_CHANNEL *_workerChannel;
    LIBSSH2_SFTP *_sftp;
    NSMutableArray<NSDictionary *> *_forwardCommands;
    NSMutableArray *_forwardRules;
    NSMutableArray *_forwardFlows;
    NSMutableDictionary *_forwardResolutions;
    id _forwardOpening;
    id _forwardListening;
    BOOL _channelOpenBusy;
    BOOL _servicingForwarding;
    int _forwardWaitDirections;
    BOOL _filesUnavailable;
    NSUInteger _forwardCursor;
    int _forwardWakeRead, _forwardWakeWrite;
    NSString *_forwardFailure;
}
- (NSString *)authenticationResponse:(NSString *)prompt echo:(BOOL)echo;
@end

@interface FCSSHClient (ForwardingWorker)
- (void)initializeForwarding;
- (BOOL)pumpForwarding;
- (BOOL)serviceInteractive;
- (BOOL)forwardingActive;
- (void)cleanupForwarding;
- (BOOL)drainForwardOpenUntil:(double)deadline;
- (void)enqueueForwardCommand:(NSString *)identifier start:(BOOL)start;
- (BOOL)queueForwardingConfiguration:(NSDictionary *)configuration start:(BOOL)start;
- (BOOL)queueForwardingRemoval:(NSString *)identifier;
- (void)waitForServiceEvents:(short)events timeout:(int)milliseconds;
+ (BOOL)forwardingListenerProbe;
@end

static inline double monotonicTime(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static inline NSDictionary *remoteSnapshot(LIBSSH2_SFTP_ATTRIBUTES attrs) {
    unsigned long type = attrs.permissions & LIBSSH2_SFTP_S_IFMT;
    return @{
        @"directory" : @(type == LIBSSH2_SFTP_S_IFDIR),
        @"regular" : @(type == LIBSSH2_SFTP_S_IFREG),
        @"size" : @(attrs.filesize),
        @"modified" : @(attrs.mtime)
    };
}

@interface FCSSHClient (TerminalWorker)
- (BOOL)pumpTerminal:(LIBSSH2_CHANNEL *)channel;
@end

@interface FCSSHClient (SFTPWorker)
- (BOOL)openSFTPUntil:(double)deadline;
- (BOOL)pumpIdleSFTP;
- (void)enqueueFileRequest:(NSDictionary *)request;
- (BOOL)approveReplacement:(NSString *)path;
- (BOOL)waitForFileUntil:(double)deadline;
- (NSDictionary *)performFileRequest:(NSDictionary *)request;
@end

@interface FCSSHClient (SFTPTreeWorker)
- (NSDictionary *)remoteAttributes:(NSString *)path;
- (NSDictionary *)localAttributes:(NSString *)path;
- (NSString *)appendName:(NSString *)name toPath:(NSString *)path;
- (BOOL)scanPath:(NSString *)path
          remote:(BOOL)remote
        relative:(NSString *)relative
           depth:(NSUInteger)depth
        manifest:(NSMutableArray *)manifest
       requestID:(NSString *)requestID;
- (BOOL)scanPath:(NSString *)path
             remote:(BOOL)remote
           relative:(NSString *)relative
              depth:(NSUInteger)depth
           manifest:(NSMutableArray *)manifest
          requestID:(NSString *)requestID
    knownAttributes:(NSDictionary *)knownAttributes;
- (NSString *)makeRemoteDirectory:(NSString *)path;
- (NSString *)removeManifest:(NSArray *)manifest root:(NSString *)root remote:(BOOL)remote;
- (NSDictionary *)performTreeOperation:(NSDictionary *)request;
@end
