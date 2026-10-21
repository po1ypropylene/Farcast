#import "SSHClientInternal.h"
#import <fcntl.h>
#import <poll.h>
#import <sys/stat.h>
#import <unistd.h>

@implementation FCSSHClient (TerminalWorker)
- (BOOL)pumpTerminal:(LIBSSH2_CHANNEL *)channel {
    _terminalWaitDirections = 0;
    if (!channel || libssh2_channel_eof(channel))
        return YES;
    NSString *failure = nil;
    if (!_terminalWrite) {
        [_lock lock];
        if (_outgoing.length)
            _terminalWrite = [_outgoing subdataWithRange:NSMakeRange(0, MIN(_outgoing.length, 32700))];
        [_lock unlock];
    }
    // New keystrokes must not change the arguments of an EAGAIN retry.
    NSData *pending = _terminalWrite;
    if (pending.length) {
        ssize_t sent = libssh2_channel_write(channel, pending.bytes, pending.length);
        if (sent == LIBSSH2_ERROR_EAGAIN)
            _terminalWaitDirections |= libssh2_session_block_directions(_workerSession);
        if (sent > 0) {
            [_lock lock];
            [_outgoing replaceBytesInRange:NSMakeRange(0, sent) withBytes:NULL length:0];
            [_lock unlock];
            _terminalWrite = nil;
        } else if (sent < 0 && sent != LIBSSH2_ERROR_EAGAIN) {
            failure = @"The SSH connection was interrupted.";
            return NO;
        }
    }
    [_lock lock];
    BOOL resize = _resizePending;
    int cols = (int)_columns;
    int rows = (int)_rows;
    [_lock unlock];
    if (resize) {
        // libssh2 retains the encoded window-change packet across EAGAIN.
        // A newer desired size must wait until that exact request completes.
        if (!_resizeInFlight) {
            _submittedColumns = cols;
            _submittedRows = rows;
            _resizeInFlight = YES;
        }
        int rc = libssh2_channel_request_pty_size(channel, _submittedColumns, _submittedRows);
        if (rc == 0) {
            _resizeInFlight = NO;
            [_lock lock];
            if (_submittedColumns == _columns && _submittedRows == _rows)
                _resizePending = NO;
            [_lock unlock];
        } else if (rc == LIBSSH2_ERROR_EAGAIN) {
            _terminalWaitDirections |= libssh2_session_block_directions(_workerSession);
        } else
            return NO;
    }
    char buffer[32768];
    for (int stream = 0; stream < 2; stream++) {
        ssize_t count = 0;
        for (int batch = 0; batch < 8 && (count = libssh2_channel_read_ex(channel, stream, buffer, sizeof(buffer))) > 0;
             batch++) {
            if (self.onData)
                self.onData([NSData dataWithBytes:buffer length:count]);
            if (atomic_load(&_stopped))
                break;
        }
        if (count < 0 && count != LIBSSH2_ERROR_EAGAIN && !libssh2_channel_eof(channel)) {
            failure = @"The SSH connection was interrupted.";
        }
        if (count == LIBSSH2_ERROR_EAGAIN)
            _terminalWaitDirections |= libssh2_session_block_directions(_workerSession);
    }
    if (failure)
        return NO;
    return YES;
}
@end
