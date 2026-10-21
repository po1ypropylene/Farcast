#import "SSHClientInternal.h"

// Deterministically backpressure the real terminal pump; all other adapter
// responsibilities still link normally. These handles are never passed to C.
static NSMutableArray<NSArray<NSNumber *> *> *sizes;
static NSMutableArray<NSData *> *writes;
static int resizeResult;
static ssize_t writeResult;
static int fixtureEOF(LIBSSH2_CHANNEL *channel) { return 0; }
static int fixtureDirections(LIBSSH2_SESSION *session) { return LIBSSH2_SESSION_BLOCK_OUTBOUND; }
static ssize_t fixtureRead(LIBSSH2_CHANNEL *channel, int stream, char *buffer, size_t length) {
    return LIBSSH2_ERROR_EAGAIN;
}
static ssize_t fixtureWrite(LIBSSH2_CHANNEL *channel, int stream, const char *buffer, size_t length) {
    [writes addObject:[NSData dataWithBytes:buffer length:length]];
    return writeResult;
}
static int fixtureResize(LIBSSH2_CHANNEL *channel, int cols, int rows, int width, int height) {
    [sizes addObject:@[ @(cols), @(rows) ]];
    return resizeResult;
}
#define libssh2_channel_eof fixtureEOF
#define libssh2_session_block_directions fixtureDirections
#define libssh2_channel_read_ex fixtureRead
#define libssh2_channel_write_ex fixtureWrite
#define libssh2_channel_request_pty_size_ex fixtureResize
#import "../../../Farcast/Native/SSH/SSHClient+Terminal.m"
#undef libssh2_channel_eof
#undef libssh2_session_block_directions
#undef libssh2_channel_read_ex
#undef libssh2_channel_write_ex
#undef libssh2_channel_request_pty_size_ex

@interface FCSSHClient (TerminalRetryFixture)
- (BOOL)pump;
- (BOOL)stopped;
@end
@implementation FCSSHClient (TerminalRetryFixture)
- (BOOL)pump {
    return [self pumpTerminal:(LIBSSH2_CHANNEL *)1];
}
- (BOOL)stopped {
    return atomic_load(&_stopped);
}
@end

int main(void) {
    @autoreleasepool {
        sizes = [NSMutableArray new];
        writes = [NSMutableArray new];
        FCSSHClient *client = [FCSSHClient new];
        [client resizeColumns:100 rows:30];
        resizeResult = LIBSSH2_ERROR_EAGAIN;
        NSCAssert([client pump], @"Resize should wait");
        [client resizeColumns:140 rows:50];
        resizeResult = 0;
        NSCAssert([client pump] && [client pump] && [client pump], @"Resize should complete");
        NSCAssert(([sizes isEqual:@[ @[ @100, @30 ], @[ @100, @30 ], @[ @140, @50 ] ]]),
                  @"EAGAIN must finish submitted geometry before sending the final desired size");
        [client resizeColumns:160 rows:60];
        resizeResult = LIBSSH2_ERROR_SOCKET_SEND;
        NSCAssert(![client pump], @"A fatal resize send must fail the transport");
        resizeResult = 0;

        client = [FCSSHClient new];
        [client sendData:[@"abc" dataUsingEncoding:NSUTF8StringEncoding]];
        writeResult = LIBSSH2_ERROR_EAGAIN;
        NSCAssert([client pump], @"Write should wait");
        [client sendData:[@"de" dataUsingEncoding:NSUTF8StringEncoding]];
        writeResult = 2;
        NSCAssert([client pump], @"Partial write should complete only acknowledged bytes");
        writeResult = 3;
        NSCAssert([client pump], @"Remaining bytes should retain order");
        NSCAssert(writes.count == 3 && [writes[0] isEqual:writes[1]] &&
                      [writes[2] isEqual:[@"cde" dataUsingEncoding:NSUTF8StringEncoding]],
                  @"Retry snapshot and partial-write ordering must remain intact");

        client = [FCSSHClient new];
        [client sendData:[NSMutableData dataWithLength:1024 * 1024]];
        NSCAssert(!client.stopped, @"Exact queue capacity is valid");
        [client sendData:[NSMutableData dataWithLength:1]];
        NSCAssert(client.stopped, @"Overflow must stop instead of silently discarding input");
        puts("PASS SSH stable PTY retry, final size, fatal resize, partial writes and explicit input overflow");
    }
    return 0;
}
