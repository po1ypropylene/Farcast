#import "SSHClient.h"
#import <fcntl.h>
#import <libssh2.h>
#import <libssh2_sftp.h>
#import <netdb.h>
#import <netinet/tcp.h>
#import <poll.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <time.h>
#import <unistd.h>

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
    BOOL _terminalUnavailable;
    NSString *_interactivePassword;
    BOOL _passwordResponseUsed;
    NSMutableArray<NSDictionary *> *_fileRequests;
    NSString *_activeFileRequest;
    LIBSSH2_SESSION *_workerSession;
    LIBSSH2_CHANNEL *_workerChannel;
    LIBSSH2_SFTP *_sftp;
}
- (NSString *)authenticationResponse:(NSString *)prompt echo:(BOOL)echo;
@end

static dispatch_group_t workers(void) {
    static dispatch_group_t group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      group = dispatch_group_create();
    });
    return group;
}

static double monotonicTime(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static NSDictionary *remoteSnapshot(LIBSSH2_SFTP_ATTRIBUTES attrs) {
    unsigned long type = attrs.permissions & LIBSSH2_SFTP_S_IFMT;
    return @{
        @"directory" : @(type == LIBSSH2_SFTP_S_IFDIR),
        @"regular" : @(type == LIBSSH2_SFTP_S_IFREG),
        @"size" : @(attrs.filesize),
        @"modified" : @(attrs.mtime)
    };
}
static void keyboardPrompt(const char *name, int nameLen, const char *instruction, int instructionLen, int count,
                           const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts, LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses,
                           void **abstract) {
    FCSSHClient *client = (__bridge FCSSHClient *)*abstract;
    for (int i = 0; i < count; i++) {
        NSString *prompt = [[NSString alloc] initWithBytes:prompts[i].text
                                                    length:prompts[i].length
                                                  encoding:NSUTF8StringEncoding]
                               ?: @"Authentication response";
        NSString *answer = [client authenticationResponse:prompt echo:prompts[i].echo != 0];
        const char *utf8 = (answer ?: @"").UTF8String;
        responses[i].text = strdup(utf8);
        responses[i].length = (unsigned int)strlen(utf8);
    }
}

@implementation FCSSHClient
+ (void)whenAllDisconnected:(void (^)(void))completion {
    dispatch_group_notify(workers(), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), completion);
}
- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _outgoing = [NSMutableData new];
        _fileRequests = [NSMutableArray new];
        _socket = -1;
        _columns = 100;
        _rows = 30;
        atomic_init(&_stopped, false);
        atomic_init(&_filesCancelled, false);
        atomic_init(&_terminalVisible, true);
    }
    return self;
}
- (void)status:(NSString *)state message:(NSString *)message {
    if (self.onStatus)
        self.onStatus(state, message);
}
- (NSString *)authenticationResponse:(NSString *)prompt echo:(BOOL)echo {
    if (atomic_load(&_stopped))
        return nil;
    NSString *normalized =
        [[prompt lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([normalized hasSuffix:@":"])
        normalized = [[normalized substringToIndex:normalized.length - 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Use the supplied password once, only for an explicitly masked password challenge.
    // Codes, passphrases, visible prompts and unrecognized questions still go to the UI.
    if (_interactivePassword && !_passwordResponseUsed && !echo &&
        ([normalized isEqualToString:@"password"] || [normalized isEqualToString:@"enter password"])) {
        _passwordResponseUsed = YES;
        return _interactivePassword;
    }
    NSString *answer = self.onPrompt ? self.onPrompt(prompt, echo) : nil;
    if (!answer)
        [self disconnect];
    return answer;
}
- (int)authenticate:(LIBSSH2_SESSION *)session
               user:(const char *)user
             length:(unsigned int)length
           password:(NSString *)password
         privateKey:(NSData *)key
             method:(NSString *)method
           deadline:(double)deadline {
    int rc;
    do {
        if ([method isEqualToString:@"publickey"])
            rc = libssh2_userauth_publickey_frommemory(session, user, length, NULL, 0, key.bytes, key.length,
                                                       password.UTF8String);
        else if ([method isEqualToString:@"keyboard-interactive"])
            rc = libssh2_userauth_keyboard_interactive_ex(session, user, length, keyboardPrompt);
        else
            rc = libssh2_userauth_password_ex(session, user, length, password.UTF8String,
                                              (unsigned int)strlen(password.UTF8String), NULL);
    } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitSocket:session deadline:deadline]);
    return rc;
}
- (void)terminalAvailable:(BOOL)available {
    [_lock lock];
    _terminalUnavailable = !available;
    if (!available) {
        [_outgoing setLength:0];
        _terminalWrite = nil;
        _resizePending = NO;
    }
    [_lock unlock];
    if (self.onTerminalAvailability)
        self.onTerminalAvailability(available);
}
- (BOOL)closeTerminal:(LIBSSH2_CHANNEL **)channel session:(LIBSSH2_SESSION *)session {
    if (!*channel)
        return YES;
    double deadline = monotonicTime() + 20;
    int rc;
    // Free also closes the channel. Finish its nonblocking state before opening SFTP.
    do {
        rc = libssh2_channel_free(*channel);
    } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitSocket:session deadline:deadline]);
    if (rc)
        return NO;
    *channel = NULL;
    _workerChannel = NULL;
    return YES;
}
- (BOOL)openSFTPUntil:(double)deadline {
    if (_sftp)
        return YES;
    do {
        _sftp = libssh2_sftp_init(_workerSession);
    } while (!_sftp && libssh2_session_last_errno(_workerSession) == LIBSSH2_ERROR_EAGAIN &&
             [self waitForFileUntil:deadline]);
    return _sftp != NULL;
}
- (BOOL)pumpIdleSFTP {
    LIBSSH2_CHANNEL *channel = libssh2_sftp_get_channel(_sftp);
    // Read only extended data: the subsystem owns all standard-stream bytes.
    // This drains SSH control packets/keepalive replies without consuming SFTP replies.
    char ignored[1024];
    ssize_t count = libssh2_channel_read_ex(channel, SSH_EXTENDED_DATA_STDERR, ignored, sizeof(ignored));
    return (count >= 0 || count == LIBSSH2_ERROR_EAGAIN) && !libssh2_channel_eof(channel);
}
- (BOOL)waitSocket:(LIBSSH2_SESSION *)session deadline:(double)deadline {
    if (atomic_load(&_stopped) || monotonicTime() >= deadline)
        return NO;
    int direction = session ? libssh2_session_block_directions(session) : 0;
    short events = session ? 0 : POLLOUT;
    if (direction & LIBSSH2_SESSION_BLOCK_INBOUND)
        events |= POLLIN;
    if (direction & LIBSSH2_SESSION_BLOCK_OUTBOUND)
        events |= POLLOUT;
    if (!events)
        events = POLLIN | POLLOUT;
    struct pollfd p = {_socket, events, 0};
    poll(&p, 1, 100);
    return !atomic_load(&_stopped) && monotonicTime() < deadline;
}
- (BOOL)openSocket:(NSString *)host port:(NSInteger)port {
    struct addrinfo hints = {0}, *addresses = NULL;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    if (getaddrinfo(host.UTF8String, [@(port).stringValue UTF8String], &hints, &addresses))
        return NO;
    BOOL connected = NO;
    double deadline = monotonicTime() + 20;
    for (struct addrinfo *a = addresses; a && !atomic_load(&_stopped); a = a->ai_next) {
        int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0)
            continue;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        fcntl(fd, F_SETFL, O_NONBLOCK);
        [_lock lock];
        _socket = fd;
        [_lock unlock];
        int rc = connect(fd, a->ai_addr, a->ai_addrlen);
        if (rc == 0)
            connected = YES;
        else if (errno == EINPROGRESS) {
            while ([self waitSocket:NULL deadline:deadline]) {
                struct pollfd p = {fd, POLLOUT, 0};
                if (poll(&p, 1, 0) > 0) {
                    int error = 0;
                    socklen_t length = sizeof(error);
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length);
                    connected = error == 0;
                    break;
                }
            }
        }
        if (connected)
            break;
        [_lock lock];
        close(fd);
        _socket = -1;
        [_lock unlock];
    }
    freeaddrinfo(addresses);
    return connected && !atomic_load(&_stopped);
}
- (void)connectHost:(NSString *)host
               port:(NSInteger)port
           username:(NSString *)username
           password:(NSString *)password
         privateKey:(NSData *)key
     authentication:(NSString *)authentication {
    // One worker owns all libssh2 handles. Public methods only enqueue input or
    // interrupt the socket.
    dispatch_group_enter(workers());
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
          [self runHost:host
                        port:port
                    username:username
                    password:password
                  privateKey:key
              authentication:authentication];
      }
      dispatch_group_leave(workers());
    });
}
- (void)runHost:(NSString *)host
              port:(NSInteger)port
          username:(NSString *)username
          password:(NSString *)password
        privateKey:(NSData *)key
    authentication:(NSString *)authentication {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      libssh2_init(0);
    });
    LIBSSH2_SESSION *session = NULL;
    LIBSSH2_CHANNEL *channel = NULL;
    NSString *failure = nil;
    NSString *fingerprint = nil;
    NSString *method = nil;
    NSString *advertisedMethods = nil;
    NSSet<NSString *> *methods = nil;
    double deadline = monotonicTime() + 30;
    int rc = 0;
    [self status:@"connecting" message:@"Connecting to server…"];
    if (![self openSocket:host port:port]) {
        failure = @"Could not reach the SSH server. Check the host, port, and network.";
        goto cleanup;
    }
    session = libssh2_session_init_ex(NULL, NULL, NULL, (__bridge void *)self);
    if (!session) {
        failure = @"Could not initialize SSH.";
        goto cleanup;
    }
    libssh2_session_set_blocking(session, 0);
    while ((rc = libssh2_session_handshake(session, _socket)) == LIBSSH2_ERROR_EAGAIN && [self waitSocket:session
                                                                                                 deadline:deadline]) {
    }
    if (rc) {
        failure = @"SSH handshake failed or timed out.";
        goto cleanup;
    }
    const char *hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (!hash) {
        failure = @"The server did not supply a verifiable host key.";
        goto cleanup;
    }
    fingerprint =
        [@"SHA256:" stringByAppendingString:[[[NSData dataWithBytes:hash length:32] base64EncodedStringWithOptions:0]
                                                stringByReplacingOccurrencesOfString:@"="
                                                                          withString:@""]];
    [self status:@"verifying" message:@"Verifying server identity…"];
    if (!self.onTrust || !self.onTrust(fingerprint, @"SSH host key")) {
        failure = @"Server identity was not trusted.";
        goto cleanup;
    }
    if (atomic_load(&_stopped))
        goto cleanup;
    [self status:@"authenticating" message:@"Signing in…"];
    deadline = monotonicTime() + 120;
    const char *user = username.UTF8String;
    unsigned int userLen = (unsigned int)strlen(user);
    const char *advertised;
    do {
        advertised = libssh2_userauth_list(session, user, userLen);
    } while (!advertised && libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN &&
             [self waitSocket:session deadline:deadline]);
    // A NULL list also represents successful "none" authentication; check it explicitly.
    if (!libssh2_userauth_authenticated(session)) {
        if (!advertised) {
            failure = @"Could not determine the server’s SSH sign-in methods.";
            goto cleanup;
        }
        advertisedMethods = [NSString stringWithUTF8String:advertised];
        if (!advertisedMethods) {
            failure = @"The server returned invalid SSH sign-in methods.";
            goto cleanup;
        }
        methods = [NSSet setWithArray:[advertisedMethods componentsSeparatedByString:@","]];
        method = [authentication isEqualToString:@"privateKey"]    ? @"publickey"
                 : [authentication isEqualToString:@"interactive"] ? @"keyboard-interactive"
                                                                   : @"password";
        if ([authentication isEqualToString:@"password"] && ![methods containsObject:method] &&
            [methods containsObject:@"keyboard-interactive"])
            method = @"keyboard-interactive";
        if (![methods containsObject:method]) {
            failure = @"The server does not support the selected SSH authentication option. Edit the connection "
                      @"and select a method supported by your server.";
            goto cleanup;
        }
        if ([authentication isEqualToString:@"password"])
            _interactivePassword = password;
        _passwordResponseUsed = NO;
        rc = [self authenticate:session
                           user:user
                         length:userLen
                       password:password
                     privateKey:key
                         method:method
                       deadline:deadline];
        if (rc == LIBSSH2_ERROR_AUTHENTICATION_FAILED && [method isEqualToString:@"password"] &&
            [methods containsObject:@"keyboard-interactive"] && !atomic_load(&_stopped) && monotonicTime() < deadline) {
            rc = [self authenticate:session
                               user:user
                             length:userLen
                           password:password
                         privateKey:key
                             method:@"keyboard-interactive"
                           deadline:deadline];
        }
        _interactivePassword = nil;
    }
    if (atomic_load(&_stopped))
        goto cleanup;
    if (rc) {
        if (rc == LIBSSH2_ERROR_AUTHENTICATION_FAILED || rc == LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED) {
            if (self.onAuthenticationRejected)
                self.onAuthenticationRejected();
            failure = @"The SSH server rejected the username or credentials. Retry sign-in to enter fresh "
                      @"credentials, or edit the connection to check the username and authentication option.";
        } else if (rc == LIBSSH2_ERROR_PASSWORD_EXPIRED)
            failure = @"The SSH password has expired. Change it with your server administrator before reconnecting.";
        else
            failure = [NSString stringWithFormat:@"SSH sign-in failed (%d) or timed out. Try connecting again.", rc];
        goto cleanup;
    }
    deadline = monotonicTime() + 20;
    do {
        channel = libssh2_channel_open_session(session);
    } while (!channel && libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN &&
             [self waitSocket:session deadline:deadline]);
    if (!channel) {
        if (libssh2_session_last_errno(session) != LIBSSH2_ERROR_CHANNEL_FAILURE) {
            failure = @"Could not open an SSH shell channel.";
            goto cleanup;
        }
    } else {
        [_lock lock];
        int cols = (int)_columns, rows = (int)_rows;
        [_lock unlock];
        do {
            rc = libssh2_channel_request_pty_ex(channel, "xterm-256color", 14, NULL, 0, cols, rows, 0, 0);
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitSocket:session deadline:deadline]);
        if (rc && rc != LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED) {
            failure = @"Could not start an interactive terminal.";
            goto cleanup;
        }
        if (!rc) {
            do {
                rc = libssh2_channel_shell(channel);
            } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitSocket:session deadline:deadline]);
            if (rc && rc != LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED) {
                failure = @"Could not start an SSH shell.";
                goto cleanup;
            }
        }
        if (rc && ![self closeTerminal:&channel session:session]) {
            failure = @"Could not close the unavailable SSH terminal.";
            goto cleanup;
        }
    }
    _workerSession = session;
    _workerChannel = channel;
    if (!channel && ![self openSFTPUntil:monotonicTime() + 30]) {
        failure = @"The server provides neither an interactive terminal nor SFTP file transfer.";
        goto cleanup;
    }
    libssh2_keepalive_config(session, 1, 30);
    [self terminalAvailable:channel != NULL];
    [self status:@"connected" message:channel ? @"SSH connected" : @"SSH connected — file transfer only"];
    while (!atomic_load(&_stopped)) {
        @autoreleasepool {
            // Forced SFTP accounts may accept the shell request and immediately close it.
            // A finished shell also need not terminate an independently usable subsystem.
            if (channel && libssh2_channel_eof(channel)) {
                if (![self closeTerminal:&channel session:session] || ![self openSFTPUntil:monotonicTime() + 30]) {
                    failure = @"The terminal ended and SFTP file transfer is unavailable.";
                    break;
                }
                [self terminalAvailable:NO];
                [self status:@"connected" message:@"SSH connected — file transfer only"];
            }
            if (channel ? ![self pumpTerminal:channel] : ![self pumpIdleSFTP]) {
                failure = @"The SSH connection was interrupted.";
                break;
            }
            [_lock lock];
            NSDictionary *request = _fileRequests.firstObject;
            if (request) {
                [_fileRequests removeObjectAtIndex:0];
                _activeFileRequest = request[@"id"];
            }
            [_lock unlock];
            if (request) {
                NSDictionary *reply = [self performFileRequest:request];
                [_lock lock];
                if (atomic_load(&_filesCancelled)) {
                    // The active handle was closed after its pending request
                    // completed. Keep the idle SFTP channel and SSH shell alive.
                    reply = @{@"error" : @"File operation cancelled."};
                    atomic_store(&_filesCancelled, false);
                }
                _activeFileRequest = nil;
                [_lock unlock];
                if (self.onFiles)
                    self.onFiles(request[@"id"], reply, reply[@"error"]);
            }
            int next = 0;
            int keepalive = libssh2_keepalive_send(session, &next);
            if (keepalive && keepalive != LIBSSH2_ERROR_EAGAIN) {
                failure = @"The SSH connection was interrupted.";
                break;
            }
            {
                struct pollfd p = {_socket, POLLIN, 0};
                poll(&p, 1, 20);
            }
        }
    }
cleanup:
    _interactivePassword = nil;
    _workerChannel = NULL;
    _workerSession = NULL;
    _terminalWrite = nil;
    [_lock lock];
    if (_socket >= 0)
        shutdown(_socket, SHUT_RDWR);
    [_lock unlock];
    if (session) {
        libssh2_session_set_blocking(session, 1);
        libssh2_session_set_timeout(session, 1000);
    }
    if (_sftp) {
        libssh2_sftp_shutdown(_sftp);
        _sftp = NULL;
    }
    if (channel) {
        libssh2_channel_close(channel);
        libssh2_channel_free(channel);
    }
    if (session) {
        libssh2_session_disconnect(session, "Disconnected");
        libssh2_session_free(session);
    }
    [_lock lock];
    if (_socket >= 0)
        close(_socket);
    _socket = -1;
    [_outgoing setLength:0];
    [_fileRequests removeAllObjects];
    [_lock unlock];
    if (failure && !atomic_load(&_stopped))
        [self status:@"failed" message:failure];
    else
        [self status:@"disconnected" message:@"SSH disconnected"];
}

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
        int rc = libssh2_channel_request_pty_size(channel, cols, rows);
        if (rc == 0) {
            [_lock lock];
            if (cols == _columns && rows == _rows)
                _resizePending = NO;
            [_lock unlock];
        } else if (rc == LIBSSH2_ERROR_EAGAIN) {
            _terminalWaitDirections |= libssh2_session_block_directions(_workerSession);
        }
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
- (void)enqueueFileRequest:(NSDictionary *)request {
    [_lock lock];
    BOOL accepted = !atomic_load(&_stopped) && _fileRequests.count < 8;
    if (accepted)
        [_fileRequests addObject:request];
    [_lock unlock];
    if (!accepted && self.onFiles)
        self.onFiles(request[@"id"], @{}, @"The file request could not be queued.");
}
- (void)listDirectory:(NSString *)path requestID:(NSString *)requestID {
    [self enqueueFileRequest:@{@"id" : requestID, @"path" : path, @"kind" : @"list"}];
}
- (void)transferLocalPath:(NSString *)localPath
               remotePath:(NSString *)remotePath
                   upload:(BOOL)upload
                requestID:(NSString *)requestID {
    [self enqueueFileRequest:@{
        @"id" : requestID,
        @"path" : remotePath,
        @"local" : localPath,
        @"kind" : upload ? @"upload" : @"download"
    }];
}
- (void)fileOperation:(NSString *)kind
               source:(NSString *)source
          destination:(NSString *)destination
                 move:(BOOL)move
            requestID:(NSString *)requestID {
    [self enqueueFileRequest:@{
        @"id" : requestID,
        @"path" : source,
        @"destination" : destination,
        @"kind" : kind,
        @"move" : @(move)
    }];
}
- (void)resolveFileConflict:(NSString *)token overwrite:(BOOL)overwrite {
    [_lock lock];
    if ([_conflictToken isEqual:token] && _conflictChoice == -1)
        _conflictChoice = overwrite ? 1 : 0;
    [_lock unlock];
}
- (BOOL)approveReplacement:(NSString *)path {
    if (!self.onFileConflict)
        return NO;
    NSString *token = NSUUID.UUID.UUIDString;
    [_lock lock];
    _conflictToken = token;
    _conflictChoice = -1;
    [_lock unlock];
    self.onFileConflict(token, path.lastPathComponent);
    NSInteger choice = -1;
    while (!atomic_load(&_stopped) && !atomic_load(&_filesCancelled)) {
        [_lock lock];
        choice = _conflictChoice;
        [_lock unlock];
        if (choice >= 0)
            break;
        if (![self pumpTerminal:_workerChannel]) {
            [self disconnect];
            break;
        }
        struct pollfd pending = {_socket, POLLIN, 0};
        poll(&pending, 1, 20);
    }
    [_lock lock];
    _conflictToken = nil;
    [_lock unlock];
    return choice == 1 && !atomic_load(&_stopped) && !atomic_load(&_filesCancelled);
}
- (BOOL)waitForFileUntil:(double)deadline {
    // Preserve SFTP's readiness directions before terminal reads change the
    // session's last-operation directions. POLLOUT must not become POLLIN.
    int direction = libssh2_session_block_directions(_workerSession);
    short events = 0;
    if (direction & LIBSSH2_SESSION_BLOCK_INBOUND)
        events |= POLLIN;
    if (direction & LIBSSH2_SESSION_BLOCK_OUTBOUND)
        events |= POLLOUT;
    if (!events)
        events = POLLIN | POLLOUT;
    if (monotonicTime() - _lastTerminalPump > 0.01) {
        _lastTerminalPump = monotonicTime();
        if (![self pumpTerminal:_workerChannel]) {
            [self disconnect];
            return NO;
        }
        // A terminal write may also need socket readiness. Preserve both
        // operations' directions, rather than waiting only for SFTP replies.
        int terminalDirection = _terminalWaitDirections;
        if (terminalDirection & LIBSSH2_SESSION_BLOCK_INBOUND)
            events |= POLLIN;
        if (terminalDirection & LIBSSH2_SESSION_BLOCK_OUTBOUND)
            events |= POLLOUT;
    }
    if (atomic_load(&_stopped) || monotonicTime() >= deadline) {
        [self disconnect];
        return NO;
    }
    struct pollfd pending = {_socket, events, 0};
    poll(&pending, 1, _workerChannel && atomic_load(&_terminalVisible) ? 10 : 50);
    return !atomic_load(&_stopped) && monotonicTime() < deadline;
}
- (NSDictionary *)performFileRequest:(NSDictionary *)request {
    if (atomic_load(&_filesCancelled))
        return @{@"error" : @"File operation cancelled."};
    NSString *requestID = request[@"id"], *path = request[@"path"];
    NSString *error = nil;
    NSDictionary *result = @{};
    LIBSSH2_SFTP_HANDLE *handle = NULL;
    int fd = -1;
    BOOL upload = [request[@"kind"] isEqualToString:@"upload"];
    BOOL listing = [request[@"kind"] isEqualToString:@"list"];
    BOOL created = NO, complete = NO;
    NSString *stagingPath = nil;
    NSString *remoteStaging = nil;
    BOOL replacing = NO;
    unsigned long long bytes = 0, total = 0;
    double deadline = monotonicTime() + 30;
    int rc = 0;
    if ([path rangeOfString:@"\0"].location != NSNotFound ||
        (request[@"local"] && [request[@"local"] rangeOfString:@"\0"].location != NSNotFound)) {
        error = @"Invalid file path.";
        goto finish;
    }
    if (![self openSFTPUntil:deadline]) {
        error = @"The server could not open SFTP. Check that file transfer is enabled.";
        goto finish;
    }
    if (![request[@"kind"] isEqualToString:@"upload"] && ![request[@"kind"] isEqualToString:@"download"] && !listing) {
        return [self performTreeOperation:request];
    }
    if (listing) {
        char canonical[32768];
        do {
            rc = libssh2_sftp_realpath(_sftp, path.UTF8String, canonical, sizeof(canonical));
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
        if (rc <= 0 || rc >= sizeof(canonical)) {
            error = @"Could not resolve this server folder.";
            goto finish;
        }
        path = [[NSString alloc] initWithBytes:canonical length:rc encoding:NSUTF8StringEncoding];
        if (!path) {
            error = @"This server path is not valid UTF-8.";
            goto finish;
        }
    } else {
        NSString *localPath = request[@"local"];
        if (!upload) {
            struct stat existing;
            int found = lstat(localPath.fileSystemRepresentation, &existing);
            if (found == 0) {
                if (!S_ISREG(existing.st_mode) || ![self approveReplacement:localPath]) {
                    error = @"Transfer stopped. Existing destination was retained.";
                    goto finish;
                }
                replacing = YES;
            } else if (errno != ENOENT) {
                error = @"Could not check the local destination.";
                goto finish;
            }
            deadline = monotonicTime() + 30;
            stagingPath = [[localPath stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:[@".farcast-transfer-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        }
        const char *local = (upload ? localPath : stagingPath).fileSystemRepresentation;
        fd = open(local, upload ? O_RDONLY | O_NOFOLLOW : O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (fd < 0) {
            error = @"Could not open the local file. Existing files are never replaced.";
            goto finish;
        }
        created = !upload;
        struct stat st;
        if (fstat(fd, &st) || !S_ISREG(st.st_mode)) {
            error = @"Select a regular file to transfer.";
            goto finish;
        }
        if (upload)
            total = st.st_size;
    }
openRemote:
    do {
        NSString *openPath = remoteStaging ?: path;
        handle = libssh2_sftp_open_ex(_sftp, openPath.UTF8String, (unsigned int)strlen(openPath.UTF8String),
                                      listing  ? 0
                                      : upload ? LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL
                                               : LIBSSH2_FXF_READ,
                                      0600, listing ? LIBSSH2_SFTP_OPENDIR : LIBSSH2_SFTP_OPENFILE);
    } while (!handle && libssh2_session_last_errno(_workerSession) == LIBSSH2_ERROR_EAGAIN &&
             [self waitForFileUntil:deadline]);
    if (!handle && upload && self.onFileConflict && !remoteStaging && !atomic_load(&_filesCancelled) &&
        !atomic_load(&_stopped)) {
        // Exclusive create is the conflict check for new destinations: one request,
        // no replacement and no symlink following. Inspect only a failed create.
        LIBSSH2_SFTP_ATTRIBUTES existing = {0};
        do {
            rc = libssh2_sftp_lstat(_sftp, path.UTF8String, &existing);
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
        if (!rc) {
            if (!(existing.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) ||
                (existing.permissions & LIBSSH2_SFTP_S_IFMT) != LIBSSH2_SFTP_S_IFREG) {
                error = @"Only regular destination files can be overwritten.";
                goto finish;
            }
            if (![self approveReplacement:path]) {
                error = @"Transfer stopped. No replacement was made.";
                goto finish;
            }
            replacing = YES;
            remoteStaging = [self appendName:[@".farcast-transfer-" stringByAppendingString:NSUUID.UUID.UUIDString]
                                      toPath:path.stringByDeletingLastPathComponent];
            deadline = monotonicTime() + 30;
            goto openRemote;
        }
    }
    if (!handle) {
        error = @"Could not open the server item. Check permissions; existing files are never replaced.";
        goto finish;
    }
    if (upload)
        created = YES;
    if (listing) {
        NSMutableArray *entries = [NSMutableArray new];
        char name[32768];
        LIBSSH2_SFTP_ATTRIBUTES attrs;
        while (!atomic_load(&_stopped)) {
            memset(&attrs, 0, sizeof(attrs));
            rc = libssh2_sftp_readdir_ex(handle, name, sizeof(name), NULL, 0, &attrs);
            if (rc == LIBSSH2_ERROR_EAGAIN) {
                if ([self waitForFileUntil:deadline])
                    continue;
                break;
            }
            if (rc <= 0 || atomic_load(&_filesCancelled))
                break;
            if (entries.count >= 20000) {
                error = @"This folder exceeds the 20,000-item limit.";
                break;
            }
            NSString *entry = [[NSString alloc] initWithBytes:name length:rc encoding:NSUTF8StringEncoding];
            if ([entry isEqualToString:@"."] || [entry isEqualToString:@".."])
                continue;
            if (!entry || [entry containsString:@"/"] || [entry rangeOfString:@"\0"].location != NSNotFound) {
                error = @"This folder contains an unsupported filename.";
                break;
            }
            unsigned long type =
                (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) ? attrs.permissions & LIBSSH2_SFTP_S_IFMT : 0;
            [entries addObject:@{
                @"name" : entry,
                @"directory" : @(type == LIBSSH2_SFTP_S_IFDIR),
                @"regular" : @(type == LIBSSH2_SFTP_S_IFREG),
                @"size" : @(attrs.filesize),
                @"snapshot" : (attrs.flags & (LIBSSH2_SFTP_ATTR_PERMISSIONS | LIBSSH2_SFTP_ATTR_SIZE |
                                              LIBSSH2_SFTP_ATTR_ACMODTIME)) ==
                        (LIBSSH2_SFTP_ATTR_PERMISSIONS | LIBSSH2_SFTP_ATTR_SIZE | LIBSSH2_SFTP_ATTR_ACMODTIME)
                    ? remoteSnapshot(attrs)
                    : @{}
            }];
            if (![self pumpTerminal:_workerChannel]) {
                [self disconnect];
                break;
            }
        }
        if (rc < 0 || atomic_load(&_stopped))
            error = @"The server folder could not be read completely.";
        result = @{@"path" : path, @"entries" : entries};
        complete = error == nil;
    } else {
        if (!upload) {
            LIBSSH2_SFTP_ATTRIBUTES attrs = {0};
            do {
                rc = libssh2_sftp_fstat(handle, &attrs);
            } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
            if (rc || !(attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) || !LIBSSH2_SFTP_S_ISREG(attrs.permissions)) {
                error = @"Only regular server files can be downloaded.";
                goto finish;
            }
            total = attrs.filesize;
        }
        // Mark each leaf's start so UI throughput never spans unrelated files.
        if (self.onFileProgress)
            self.onFileProgress(requestID, 0, total);
        // Files-only presentation retains the bulk pipeline. Interactive
        // presentation bounds data queued ahead of terminal packets on the
        // shared TCP stream (SFTP reads request four times the offered size).
        NSUInteger maximumWindow = upload ? 4 * 1024 * 1024 : 1024 * 1024;
        NSUInteger windowSize = (NSUInteger)MIN(MAX(1ULL, total), maximumWindow);
        NSMutableData *window = [NSMutableData dataWithLength:windowSize];
        char *buffer = window.mutableBytes;
        size_t bufferSize = window.length;
        double lastProgress = 0;
        while (!atomic_load(&_stopped) && !atomic_load(&_filesCancelled)) {
            size_t budget = _workerChannel && atomic_load(&_terminalVisible)
                                ? MIN(bufferSize, upload ? 128 * 1024 : 32 * 1024)
                                : bufferSize;
            ssize_t count;
            do {
                count = upload ? read(fd, buffer, budget) : libssh2_sftp_read(handle, buffer, budget);
            } while (!upload && count == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
            if (atomic_load(&_filesCancelled))
                break;
            if (count == 0) {
                complete = bytes == total;
                break;
            }
            if (count < 0)
                break;
            ssize_t offset = 0;
            size_t offered = 0;
            while (offset < count && !atomic_load(&_stopped)) {
                if (!offered) {
                    budget =
                        _workerChannel && atomic_load(&_terminalVisible) ? MIN(bufferSize, 128 * 1024) : bufferSize;
                    offered = MIN(count - offset, budget);
                }
                ssize_t written = upload ? libssh2_sftp_write(handle, buffer + offset, offered)
                                         : write(fd, buffer + offset, count - offset);
                if (upload && (written == LIBSSH2_ERROR_EAGAIN || written == 0)) {
                    if ([self waitForFileUntil:deadline])
                        continue;
                    break;
                }
                if (written <= 0)
                    break;
                offset += written;
                bytes += written;
                offered = 0;
                deadline = monotonicTime() + 30;
                // Refill only after a positive acknowledgement, never on EAGAIN:
                // libssh2 requires identical unacknowledged bytes on retries.
                // Keeping the bounded window full avoids draining it between reads.
                if (upload && offset >= MAX(32 * 1024, budget / 4) && !atomic_load(&_filesCancelled)) {
                    size_t remaining = count - offset;
                    memmove(buffer, buffer + offset, remaining);
                    // After switching to Split, drain previously queued bulk
                    // bytes before adding more; a TCP stream cannot reorder them.
                    ssize_t added = remaining < budget ? read(fd, buffer + remaining, budget - remaining) : 0;
                    if (added < 0) {
                        error = @"Could not read the upload source.";
                        break;
                    }
                    count = remaining + added;
                    offset = 0;
                    if (self.onFileProgress && monotonicTime() - lastProgress >= 0.1) {
                        self.onFileProgress(requestID, bytes, total);
                        lastProgress = monotonicTime();
                    }
                }
                if (upload && monotonicTime() - _lastTerminalPump >= 0.01) {
                    _lastTerminalPump = monotonicTime();
                    if (![self pumpTerminal:_workerChannel]) {
                        [self disconnect];
                        break;
                    }
                }
            }
            if (offset != count)
                break;
            if (![self pumpTerminal:_workerChannel]) {
                [self disconnect];
                break;
            }
            if (self.onFileProgress && monotonicTime() - lastProgress >= 0.1) {
                self.onFileProgress(requestID, bytes, total);
                lastProgress = monotonicTime();
            }
        }
        if (!complete)
            error = @"Transfer interrupted. An incomplete file may remain on the server.";
        if (complete && self.onFileProgress)
            self.onFileProgress(requestID, bytes, total);
        result = @{@"bytes" : @(bytes)};
    }
finish:
    if (handle) {
        // Download read-ahead can leave up to four windows of replies ahead
        // of CLOSE on a slow peer. Allow bounded draining without abandoning
        // the shared login, and keep servicing terminal I/O while it completes.
        double closeDeadline = monotonicTime() + (upload || listing ? 5 : 10);
        do {
            rc = libssh2_sftp_close_handle(handle);
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:closeDeadline]);
        if (rc) {
            error = @"The server did not confirm closing the file. Check for an incomplete file.";
            complete = NO;
            [self disconnect];
        }
    }
    if (fd >= 0) {
        if (!upload && complete && fsync(fd)) {
            complete = NO;
            error = @"Could not finish writing the local file.";
        }
        close(fd);
    }
    if (!upload && created) {
        if (complete &&
            (replacing ? rename(stagingPath.fileSystemRepresentation, [request[@"local"] fileSystemRepresentation])
                       : link(stagingPath.fileSystemRepresentation, [request[@"local"] fileSystemRepresentation]))) {
            error = @"Could not save the download. The destination may already exist; no existing file was replaced.";
            complete = NO;
        }
        unlink(stagingPath.fileSystemRepresentation);
    }
    if (remoteStaging) {
        if (complete && !atomic_load(&_filesCancelled) && !atomic_load(&_stopped)) {
            // Atomic replacement never follows a destination symlink, and preserves
            // the old bytes until the entire upload and handle close succeed.
            deadline = monotonicTime() + 30;
            do {
                rc = libssh2_sftp_posix_rename(_sftp, remoteStaging.UTF8String, path.UTF8String);
            } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
            if (rc)
                error = @"The server could not atomically replace the file. The original was retained.";
        }
        if (!complete || error || atomic_load(&_filesCancelled)) {
            deadline = monotonicTime() + 5;
            do {
                rc = libssh2_sftp_unlink(_sftp, remoteStaging.UTF8String);
            } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
        }
    }
    // Leave an interrupted upload for the user to inspect. Deleting by remote
    // pathname could remove another client's replacement on a shared server.
    if (error)
        return @{@"error" : error};
    return result;
}

// Recursive operations stay on the transport worker. A manifest is built before
// changing the destination: symlinks/special files fail rather than silently skip.
- (NSDictionary *)remoteAttributes:(NSString *)path {
    LIBSSH2_SFTP_ATTRIBUTES attrs = {0};
    double deadline = monotonicTime() + 30;
    int rc;
    do {
        rc = libssh2_sftp_lstat(_sftp, path.UTF8String, &attrs);
    } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
    if (rc || !(attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS))
        return @{@"error" : @"Could not inspect the server item."};
    return remoteSnapshot(attrs);
}
- (NSDictionary *)localAttributes:(NSString *)path {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st))
        return @{@"error" : @"Could not inspect the local item."};
    return @{
        @"directory" : @(S_ISDIR(st.st_mode)),
        @"regular" : @(S_ISREG(st.st_mode)),
        @"size" : @(S_ISREG(st.st_mode) ? st.st_size : 0),
        @"modified" : @(st.st_mtimespec.tv_sec),
        @"nanos" : @(st.st_mtimespec.tv_nsec),
        @"inode" : @(st.st_ino)
    };
}
- (NSString *)appendName:(NSString *)name toPath:(NSString *)path {
    return [path isEqual:@"/"] ? [@"/" stringByAppendingString:name] : [NSString stringWithFormat:@"%@/%@", path, name];
}
- (BOOL)scanPath:(NSString *)path
          remote:(BOOL)remote
        relative:(NSString *)relative
           depth:(NSUInteger)depth
        manifest:(NSMutableArray *)manifest
       requestID:(NSString *)requestID {
    if (atomic_load(&_stopped) || atomic_load(&_filesCancelled) || depth > 64 || manifest.count >= 20000)
        return NO;
    return [self scanPath:path
                   remote:remote
                 relative:relative
                    depth:depth
                 manifest:manifest
                requestID:requestID
          knownAttributes:nil];
}
- (BOOL)scanPath:(NSString *)path
             remote:(BOOL)remote
           relative:(NSString *)relative
              depth:(NSUInteger)depth
           manifest:(NSMutableArray *)manifest
          requestID:(NSString *)requestID
    knownAttributes:(NSDictionary *)knownAttributes {
    if (atomic_load(&_stopped) || atomic_load(&_filesCancelled) || depth > 64 || manifest.count >= 20000)
        return NO;
    // READDIR already carries metadata. Reuse complete snapshots for preflight,
    // with LSTAT fallback for servers omitting fields. Transfer-time source
    // identity/metadata rechecks and move-deletion checks remain independent.
    NSDictionary *attrs = knownAttributes ?: (remote ? [self remoteAttributes:path] : [self localAttributes:path]);
    if (attrs[@"error"] || (![attrs[@"directory"] boolValue] && ![attrs[@"regular"] boolValue]))
        return NO;
    [manifest addObject:@{@"relative" : relative, @"attributes" : attrs}];
    if (![attrs[@"directory"] boolValue])
        return YES;
    NSArray *names;
    NSMutableDictionary *snapshots = [NSMutableDictionary new];
    if (remote) {
        NSDictionary *listing = [self performFileRequest:@{@"id" : requestID, @"path" : path, @"kind" : @"list"}];
        if (listing[@"error"])
            return NO;
        names = [listing[@"entries"] valueForKey:@"name"];
        for (NSDictionary *entry in listing[@"entries"]) {
            NSDictionary *snapshot = entry[@"snapshot"];
            if (snapshot.count)
                snapshots[entry[@"name"]] = snapshot;
        }
    } else {
        names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
        if (!names)
            return NO;
    }
    names = [names sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        if (!name.length || [name isEqual:@"."] || [name isEqual:@".."] || [name containsString:@"/"] ||
            [name rangeOfString:@"\0"].location != NSNotFound)
            return NO;
        NSString *child = [self appendName:name toPath:path];
        NSString *rel = relative.length ? [self appendName:name toPath:relative] : name;
        if (![self scanPath:child
                         remote:remote
                       relative:rel
                          depth:depth + 1
                       manifest:manifest
                      requestID:requestID
                knownAttributes:snapshots[name]])
            return NO;
    }
    return YES;
}
- (NSString *)makeRemoteDirectory:(NSString *)path {
    int rc;
    double deadline = monotonicTime() + 30;
    do {
        rc = libssh2_sftp_mkdir(_sftp, path.UTF8String, 0700);
    } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
    return rc ? @"Could not create the server folder. Existing items are never replaced." : nil;
}
- (NSString *)removeManifest:(NSArray *)manifest root:(NSString *)root remote:(BOOL)remote {
    for (NSDictionary *entry in [manifest reverseObjectEnumerator]) {
        if (atomic_load(&_stopped) || atomic_load(&_filesCancelled))
            return @"Deletion interrupted; some source items may remain.";
        NSString *rel = entry[@"relative"];
        NSString *path = rel.length ? [self appendName:rel toPath:root] : root;
        BOOL directory = [entry[@"attributes"][@"directory"] boolValue];
        NSDictionary *current = remote ? [self remoteAttributes:path] : [self localAttributes:path];
        if (current[@"error"] ||
            (directory ? ![current[@"directory"] boolValue] : ![current isEqual:entry[@"attributes"]]))
            return @"A source item changed during deletion. Stopped; some source items may remain.";
        if (remote) {
            int rc;
            double deadline = monotonicTime() + 30;
            do {
                rc = directory ? libssh2_sftp_rmdir(_sftp, path.UTF8String)
                               : libssh2_sftp_unlink(_sftp, path.UTF8String);
            } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
            if (rc)
                return @"Could not remove a source item. Some items may remain.";
        } else {
            int rc = directory ? rmdir(path.fileSystemRepresentation) : unlink(path.fileSystemRepresentation);
            if (rc)
                return @"Could not remove a local source item. Some items may remain.";
        }
        if (![self pumpTerminal:_workerChannel]) {
            [self disconnect];
            return @"Connection interrupted.";
        }
    }
    return nil;
}
- (NSDictionary *)performTreeOperation:(NSDictionary *)request {
    NSString *kind = request[@"kind"], *source = request[@"path"], *destination = request[@"destination"],
             *requestID = request[@"id"];
    if ([destination rangeOfString:@"\0"].location != NSNotFound)
        return @{@"error" : @"Invalid destination path."};
    if ([kind isEqual:@"mkdir"]) {
        NSString *failure = [self makeRemoteDirectory:source];
        return failure ? @{@"error" : failure} : @{};
    }
    if ([kind isEqual:@"rename"]) {
        if ([source isEqual:destination] || [destination hasPrefix:[source stringByAppendingString:@"/"]])
            return @{@"error" : @"Choose a different destination outside the source folder."};
        LIBSSH2_SFTP_ATTRIBUTES attrs = {0};
        int rc;
        double deadline = monotonicTime() + 30;
        do {
            rc = libssh2_sftp_lstat(_sftp, destination.UTF8String, &attrs);
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
        if (rc == 0 || libssh2_sftp_last_error(_sftp) != LIBSSH2_FX_NO_SUCH_FILE)
            return @{@"error" : @"The destination exists or cannot be checked."};
        do {
            rc = libssh2_sftp_rename_ex(_sftp, source.UTF8String, (unsigned int)strlen(source.UTF8String),
                                        destination.UTF8String, (unsigned int)strlen(destination.UTF8String), 0);
        } while (rc == LIBSSH2_ERROR_EAGAIN && [self waitForFileUntil:deadline]);
        return rc ? @{@"error" : @"Could not rename or move the server item. No replacement was requested."} : @{};
    }
    BOOL upload = [kind isEqual:@"uploadTree"];
    BOOL remoteCopy = [kind isEqual:@"copyRemote"];
    BOOL remove = [kind isEqual:@"removeTree"];
    if (!upload && !remoteCopy && !remove && ![kind isEqual:@"downloadTree"])
        return @{@"error" : @"Unsupported file operation."};
    if ([source isEqual:@"/"] || [source isEqual:@"."] || [source isEqual:@".."] || [source hasSuffix:@"/.."] ||
        [source hasSuffix:@"/."])
        return @{@"error" : @"Select an item inside a folder."};
    if (remoteCopy) {
        // Canonicalize the destination parent so ../ cannot bypass the descendant guard.
        NSString *parent = [destination stringByDeletingLastPathComponent];
        NSDictionary *resolved = [self performFileRequest:@{@"kind" : @"list", @"path" : parent, @"id" : requestID}];
        if (resolved[@"error"])
            return resolved;
        destination = [self appendName:destination.lastPathComponent toPath:resolved[@"path"]];
        NSDictionary *srcParent = [self performFileRequest:@{
            @"kind" : @"list",
            @"path" : source.stringByDeletingLastPathComponent,
            @"id" : requestID
        }];
        if (srcParent[@"error"])
            return srcParent;
        source = [self appendName:source.lastPathComponent toPath:srcParent[@"path"]];
        if ([source isEqual:destination] || [destination hasPrefix:[source stringByAppendingString:@"/"]])
            return @{@"error" : @"A folder cannot be pasted into itself."};
    }
    NSMutableArray *manifest = [NSMutableArray new];
    if (![self scanPath:source remote:!upload relative:@"" depth:0 manifest:manifest requestID:requestID])
        return @{
            @"error" : @"Could not read the complete source tree. Links, special files, more than 20,000 items or more "
                       @"than 64 folder levels are not supported. No source items were removed."
        };
    if (remove) {
        NSString *failure = [self removeManifest:manifest root:source remote:YES];
        return failure ? @{@"error" : failure} : @{};
    }
    NSString *temporary = nil;
    NSString *target = destination;
    if (remoteCopy) {
        NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Farcast-copy-XXXXXX"];
        char *buffer = strdup(template.fileSystemRepresentation);
        char *made = mkdtemp(buffer);
        if (made)
            temporary = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:made length:strlen(made)];
        free(buffer);
        if (!temporary)
            return @{@"error" : @"Could not create a temporary transfer folder."};
        target = [temporary stringByAppendingPathComponent:@"item"];
    }
    NSString *failure = nil;
    for (NSDictionary *entry in manifest) {
        if (atomic_load(&_stopped) || atomic_load(&_filesCancelled)) {
            failure = @"Transfer cancelled. Partial destination items may remain; sources were retained.";
            break;
        }
        NSString *rel = entry[@"relative"];
        NSString *src = rel.length ? [self appendName:rel toPath:source] : source;
        NSString *dst = rel.length ? [self appendName:rel toPath:target] : target;
        NSDictionary *current = upload ? [self localAttributes:src] : [self remoteAttributes:src];
        if (![current isEqual:entry[@"attributes"]]) {
            failure = @"A source item changed. Stopped without removing sources; partial destination items may remain.";
            break;
        }
        if ([entry[@"attributes"][@"directory"] boolValue]) {
            NSDictionary *existing =
                self.onFileConflict ? (upload ? [self remoteAttributes:dst] : [self localAttributes:dst]) : nil;
            if (![existing[@"directory"] boolValue]) {
                if (upload)
                    failure = [self makeRemoteDirectory:dst];
                else if (mkdir(dst.fileSystemRepresentation, 0700))
                    failure = @"Could not create a local destination folder. Existing items are never replaced.";
            }
        } else {
            NSDictionary *leaf = [self performFileRequest:@{
                @"id" : requestID,
                @"kind" : upload ? @"upload" : @"download",
                @"local" : upload ? src : dst,
                @"path" : upload ? dst : src
            }];
            failure = leaf[@"error"];
        }
        if (failure)
            break;
    }
    if (!failure && remoteCopy) {
        NSDictionary *copied = [self performTreeOperation:@{
            @"id" : requestID,
            @"kind" : @"uploadTree",
            @"path" : target,
            @"destination" : destination,
            @"move" : @NO
        }];
        failure = copied[@"error"];
    }
    if (temporary)
        [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
    if (!failure && [request[@"move"] boolValue]) {
        NSMutableArray *current = [NSMutableArray new];
        if (![self scanPath:source remote:!upload relative:@"" depth:0 manifest:current requestID:requestID] ||
            ![current isEqual:manifest])
            failure = @"The copy completed, but the source changed. The source was not removed.";
        else
            failure = [self removeManifest:manifest root:source remote:!upload];
    }
    if (failure)
        return @{@"error" : failure};
    return @{@"items" : @(manifest.count)};
}

- (void)setTerminalVisible:(BOOL)visible {
    atomic_store(&_terminalVisible, visible);
}
- (void)sendData:(NSData *)data {
    [_lock lock];
    if (!_terminalUnavailable && !atomic_load(&_stopped) && _outgoing.length + data.length <= 1024 * 1024)
        [_outgoing appendData:data];
    [_lock unlock];
}
- (void)resizeColumns:(NSInteger)columns rows:(NSInteger)rows {
    [_lock lock];
    _columns = MAX(1, columns);
    _rows = MAX(1, rows);
    _resizePending = YES;
    [_lock unlock];
}
- (void)cancelFiles {
    [_lock lock];
    if (_activeFileRequest || _fileRequests.count)
        atomic_store(&_filesCancelled, true);
    [_lock unlock];
}
- (void)disconnect {
    atomic_store(&_stopped, true);
    [_lock lock];
    if (_socket >= 0)
        shutdown(_socket, SHUT_RDWR);
    [_lock unlock];
}
@end
