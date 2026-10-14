#import "../Transport/WireGuardSocket.h"
#import "SSHClientInternal.h"
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

static dispatch_group_t workers(void) {
    static dispatch_group_t group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      group = dispatch_group_create();
    });
    return group;
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
+ (BOOL)verifyForwardingListener {
    return [self forwardingListenerProbe];
}
- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _outgoing = [NSMutableData new];
        _fileRequests = [NSMutableArray new];
        _forwardCommands = [NSMutableArray new];
        _forwardResolutions = [NSMutableDictionary new];
        _forwardingRules = @[];
        _forwardWakeRead = _forwardWakeWrite = -1;
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
    int wake[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, wake) == 0) {
        _forwardWakeRead = wake[0];
        _forwardWakeWrite = wake[1];
        for (int i = 0; i < 2; i++) {
            int one = 1;
            fcntl(wake[i], F_SETFL, O_NONBLOCK);
            fcntl(wake[i], F_SETFD, FD_CLOEXEC);
            setsockopt(wake[i], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        }
    }
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
    if (self.tunnelPort != 0 || self.tunnelToken != nil) {
        failure = FCWireGuardSocketFailure(0);
        if (self.tunnelPort <= 0 || self.tunnelPort > 65535 || self.tunnelToken.length != 64 ||
            ![self openSocket:@"127.0.0.1" port:self.tunnelPort])
            goto cleanup;
        if (!FCWireGuardAuthenticateSocket(
                _socket, self.tunnelToken,
                ^BOOL {
                  return atomic_load(&self->_stopped);
                },
                &failure))
            goto cleanup;
        // Tunnel dialing has its own deadline; SSH starts its handshake now.
        deadline = monotonicTime() + 30;
    } else if (![self openSocket:host port:port]) {
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
    [self initializeForwarding];
    if (!channel && ![self openSFTPUntil:monotonicTime() + 30]) {
        if (!_forwardRules.count) {
            failure = @"The server provides neither an interactive terminal nor SFTP file transfer.";
            goto cleanup;
        }
    }
    // Global request replies have no IDs. libssh2's keepalive sender does not
    // consume its reply, so it would be mistaken for a forward-listen reply.
    libssh2_keepalive_config(session, 0, 30);
    [self terminalAvailable:channel != NULL];
    [self status:@"connected"
         message:channel             ? @"SSH connected"
                 : _filesUnavailable ? @"SSH connected — tunnels only"
                                     : @"SSH connected — file transfer only"];
    while (!atomic_load(&_stopped)) {
        @autoreleasepool {
            // Forced SFTP accounts may accept the shell request and immediately close it.
            // A finished shell also need not terminate an independently usable subsystem.
            if (channel && libssh2_channel_eof(channel)) {
                if (![self closeTerminal:&channel session:session] ||
                    (![self openSFTPUntil:monotonicTime() + 30] && !_forwardRules.count)) {
                    failure = @"The terminal ended and SFTP file transfer is unavailable.";
                    break;
                }
                [self terminalAvailable:NO];
                [self status:@"connected"
                     message:_filesUnavailable ? @"SSH connected — tunnels only"
                                               : @"SSH connected — file transfer only"];
            }
            if (![self serviceInteractive] || (!channel && _sftp && ![self pumpIdleSFTP])) {
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
            [self waitForServiceEvents:POLLIN timeout:20];
        }
    }
cleanup:
    [self cleanupForwarding];
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
    if (_forwardWakeRead >= 0)
        close(_forwardWakeRead);
    if (_forwardWakeWrite >= 0)
        close(_forwardWakeWrite);
    _forwardWakeRead = _forwardWakeWrite = -1;
    [_lock unlock];
    if (_forwardFailure || (failure && !atomic_load(&_stopped)))
        [self status:@"failed" message:_forwardFailure ?: failure];
    else
        [self status:@"disconnected" message:@"SSH disconnected"];
}

- (void)listDirectory:(NSString *)path requestID:(NSString *)requestID {
    [self enqueueFileRequest:@{@"id" : requestID, @"path" : path, @"kind" : @"list"}];
}
- (BOOL)updateForwarding:(NSDictionary *)configuration start:(BOOL)start {
    return [self queueForwardingConfiguration:configuration start:start];
}
- (BOOL)removeForwarding:(NSString *)identifier {
    return [self queueForwardingRemoval:identifier];
}
- (void)startForwarding:(NSString *)identifier {
    [self enqueueForwardCommand:identifier start:YES];
}
- (void)stopForwarding:(NSString *)identifier {
    [self enqueueForwardCommand:identifier start:NO];
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
