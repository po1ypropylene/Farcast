#import "SSHClientInternal.h"
#import <arpa/inet.h>
#import <fcntl.h>
#import <netdb.h>
#import <netinet/tcp.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

// Independently written channel engine. Only the SSH worker touches these objects.
static const NSUInteger bufferLimit = 256 * 1024, aggregateLimit = 16 * 1024 * 1024;
@interface FCForwardRule : NSObject
@property NSDictionary *configuration;
@property NSString *identifier;
@property NSString *kind;
@property NSString *state;
@property NSString *message;
@property NSString *published;
@property BOOL wanted;
@property NSDictionary *replacement;
@property BOOL replacementStarts;
@property BOOL removing;
@property int socket;
@property LIBSSH2_LISTENER *listener;
@property NSInteger port;
@property double deadline;
@end
@implementation FCForwardRule
- (instancetype)init {
    if ((self = [super init])) {
        _socket = -1;
        _state = @"stopped";
        _message = @"";
    }
    return self;
}
@end

typedef NS_ENUM(NSInteger, FCFlowPhase) {
    FCFlowGreeting,
    FCFlowRequest,
    FCFlowOpening,
    FCFlowResolving,
    FCFlowConnecting,
    FCFlowStreaming,
    FCFlowClosing,
    FCFlowFlushError
};
@interface FCForwardFlow : NSObject
@property FCForwardRule *rule;
@property NSString *identifier;
@property NSString *host;
@property NSInteger port;
@property NSString *origin;
@property NSInteger originPort;
@property int socket;
@property LIBSSH2_CHANNEL *channel;
@property FCFlowPhase phase;
@property NSMutableData *up;
@property NSMutableData *down;
@property NSData *write;
@property NSArray<NSData *> *addresses;
@property NSUInteger addressIndex;
@property double deadline;
@property BOOL socks;
@property BOOL localEOF;
@property BOOL remoteEOF;
@property BOOL sentEOF;
@property BOOL socketEOF;
@property double closeDeadline;
@end
@implementation FCForwardFlow
- (instancetype)init {
    if ((self = [super init])) {
        _socket = -1;
        _identifier = NSUUID.UUID.UUIDString;
        _up = [NSMutableData new];
        _down = [NSMutableData new];
        _deadline = monotonicTime() + 20;
    }
    return self;
}
@end

static void prepareSocket(int fd) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    fcntl(fd, F_SETFL, O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
}
static BOOL numericAddress(NSString *host, NSInteger port, struct sockaddr_storage *storage, socklen_t *length) {
    memset(storage, 0, sizeof(*storage));
    struct sockaddr_in *v4 = (void *)storage;
    struct sockaddr_in6 *v6 = (void *)storage;
    if (inet_pton(AF_INET, host.UTF8String, &v4->sin_addr) == 1) {
        v4->sin_family = AF_INET;
        v4->sin_len = sizeof(*v4);
        v4->sin_port = htons((uint16_t)port);
        *length = sizeof(*v4);
        return YES;
    }
    if (inet_pton(AF_INET6, host.UTF8String, &v6->sin6_addr) == 1) {
        v6->sin6_family = AF_INET6;
        v6->sin6_len = sizeof(*v6);
        v6->sin6_port = htons((uint16_t)port);
        *length = sizeof(*v6);
        return YES;
    }
    return NO;
}
static BOOL validDestination(NSString *host, NSInteger port) {
    if (![host isKindOfClass:NSString.class] || !host.length ||
        [host lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255 || port < 1 || port > 65535 ||
        [host rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
        [host rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        [host containsString:@"/"])
        return NO;
    if ([host containsString:@":"]) {
        struct sockaddr_storage address;
        socklen_t length;
        return numericAddress(host, port, &address, &length);
    }
    return YES;
}
static void consume(NSMutableData *data, NSUInteger count) {
    [data replaceBytesInRange:NSMakeRange(0, count) withBytes:NULL length:0];
}

@implementation FCSSHClient (ForwardingWorker)
+ (BOOL)forwardingListenerProbe {
    for (NSString *address in @[ @"127.0.0.1", @"::1" ]) {
        FCSSHClient *client = [FCSSHClient new];
        client.forwardingRules = @[
            @{@"id" : NSUUID.UUID.UUIDString, @"kind" : @"socks", @"bind" : address, @"port" : @0, @"enabled" : @NO}
        ];
        [client initializeForwarding];
        FCForwardRule *rule = client->_forwardRules.firstObject;
        if (!rule || ![client startLocalRule:rule]) {
            fprintf(stderr, "SSH listener probe: bind failed (%d).\n", errno);
            return NO;
        }
        struct sockaddr_storage storage;
        socklen_t length;
        numericAddress(address, rule.port, &storage, &length);
        int peer = socket(storage.ss_family, SOCK_STREAM, 0);
        BOOL success = NO;
        if (peer >= 0) {
            prepareSocket(peer);
            int connected = connect(peer, (void *)&storage, length);
            if (connected == 0 || errno == EINPROGRESS) {
                double deadline = monotonicTime() + 3;
                struct pollfd readiness = {peer, POLLOUT, 0};
                int error = 0;
                socklen_t errorLength = sizeof(error);
                if (poll(&readiness, 1, 2000) > 0 && !getsockopt(peer, SOL_SOCKET, SO_ERROR, &error, &errorLength) &&
                    !error) {
                    readiness = (struct pollfd){rule.socket, POLLIN, 0};
                    poll(&readiness, 1, 1000);
                    [client acceptLocalRule:rule];
                    FCForwardFlow *flow = client->_forwardFlows.firstObject;
                    uint8_t byte = 9, received = 0;
                    if (flow) {
                        BOOL sent = NO;
                        while (!success && monotonicTime() < deadline) {
                            if (!sent) {
                                ssize_t count = send(peer, &byte, 1, 0);
                                if (count == 1)
                                    sent = YES;
                                else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
                                    break;
                            }
                            readiness = (struct pollfd){flow.socket, POLLIN, 0};
                            if (sent && poll(&readiness, 1, 20) > 0) {
                                ssize_t count = recv(flow.socket, &received, 1, 0);
                                success = count == 1 && received == byte;
                                if (count == 0 ||
                                    (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
                                    break;
                            }
                        }
                    }
                }
            }
            close(peer);
        }
        [client cleanupForwarding];
        if (!success) {
            fprintf(stderr, "SSH listener probe: accept/data failed (%d).\n", errno);
            return NO;
        }
    }
    return YES;
}
- (void)enqueueForwardCommand:(NSString *)identifier start:(BOOL)start {
    if (![identifier isKindOfClass:NSString.class])
        return;
    [_lock lock];
    if (!atomic_load(&_stopped) && _forwardCommands.count < 32) {
        [_forwardCommands addObject:@{@"id" : identifier, @"start" : @(start)}];
        if (_forwardWakeWrite >= 0) {
            uint8_t byte = 1;
            send(_forwardWakeWrite, &byte, 1, 0);
        }
    }
    [_lock unlock];
}
- (BOOL)enqueueRuntimeForwardCommand:(NSDictionary *)command {
    [_lock lock];
    BOOL accepted = !atomic_load(&_stopped) && _forwardCommands.count < 32;
    if (accepted) {
        [_forwardCommands addObject:command];
        if (_forwardWakeWrite >= 0) {
            uint8_t byte = 1;
            send(_forwardWakeWrite, &byte, 1, 0);
        }
    }
    [_lock unlock];
    return accepted;
}
- (BOOL)queueForwardingConfiguration:(NSDictionary *)configuration start:(BOOL)start {
    if (![configuration isKindOfClass:NSDictionary.class] || ![self validForwardConfiguration:configuration])
        return NO;
    return [self enqueueRuntimeForwardCommand:@{
        @"id" : configuration[@"id"],
        @"configuration" : [configuration copy],
        @"start" : @(start)
    }];
}
- (BOOL)queueForwardingRemoval:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier])
        return NO;
    return [self enqueueRuntimeForwardCommand:@{@"id" : identifier, @"remove" : @YES}];
}
- (BOOL)validForwardConfiguration:(NSDictionary *)configuration {
    NSString *identifier = configuration[@"id"], *kind = configuration[@"kind"], *bind = configuration[@"bind"];
    if (![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier] ||
        ![kind isKindOfClass:NSString.class] || ![bind isKindOfClass:NSString.class] ||
        ![configuration[@"port"] isKindOfClass:NSNumber.class])
        return NO;
    NSInteger port = [configuration[@"port"] integerValue];
    struct sockaddr_storage address;
    socklen_t length;
    return [@[ @"local", @"socks", @"remote" ] containsObject:kind] && port >= 0 && port <= 65535 &&
           numericAddress(bind, port, &address, &length) &&
           ([kind isEqual:@"remote"] || [@[ @"127.0.0.1", @"::1" ] containsObject:bind]) &&
           ([kind isEqual:@"socks"] ||
            ([configuration[@"destinationPort"] isKindOfClass:NSNumber.class] &&
             validDestination(configuration[@"host"], [configuration[@"destinationPort"] integerValue])));
}
- (FCForwardRule *)makeForwardRule:(NSDictionary *)configuration start:(BOOL)start {
    FCForwardRule *rule = [FCForwardRule new];
    rule.configuration = [configuration copy];
    rule.identifier = configuration[@"id"];
    rule.kind = configuration[@"kind"];
    rule.wanted = start;
    rule.state = start ? @"starting" : @"stopped";
    rule.deadline = monotonicTime() + 20;
    return rule;
}
- (void)initializeForwarding {
    _forwardRules = [NSMutableArray new];
    _forwardFlows = [NSMutableArray new];
    NSMutableSet *identifiers = [NSMutableSet new];
    for (NSDictionary *configuration in self.forwardingRules) {
        if (![configuration isKindOfClass:NSDictionary.class])
            continue;
        NSString *identifier = configuration[@"id"];
        if (![self validForwardConfiguration:configuration] || [identifiers containsObject:identifier] ||
            _forwardRules.count >= 16) {
            if (self.onForwarding && [identifier isKindOfClass:NSString.class])
                self.onForwarding(identifier, @"failed", 0, 0, @"Invalid or excessive tunnels. Edit the connection.");
            continue;
        }
        [identifiers addObject:identifier];
        [_forwardRules addObject:[self makeForwardRule:configuration start:[configuration[@"enabled"] boolValue]]];
    }
}
- (BOOL)forwardingActive {
    for (FCForwardRule *rule in _forwardRules)
        if (rule.wanted || rule.listener || rule.socket >= 0)
            return YES;
    return _forwardFlows.count > 0;
}
- (void)publishRule:(FCForwardRule *)rule {
    NSUInteger count = 0;
    for (FCForwardFlow *flow in _forwardFlows)
        if (flow.rule == rule && flow.phase != FCFlowClosing)
            count++;
    NSString *snapshot = [NSString stringWithFormat:@"%@|%ld|%lu|%@", rule.state, (long)rule.port, count, rule.message];
    if (![snapshot isEqual:rule.published]) {
        rule.published = snapshot;
        if (self.onForwarding)
            self.onForwarding(rule.identifier, rule.state, rule.port, count, rule.message);
    }
}
- (void)captureForwardWait {
    _forwardWaitDirections |= libssh2_session_block_directions(_workerSession);
}
- (void)failFlow:(FCForwardFlow *)flow code:(uint8_t)code message:(NSString *)message {
    flow.rule.message = [@"Last connection: " stringByAppendingString:message];
    if (flow.socks && flow.phase == FCFlowOpening && flow.socket >= 0) {
        uint8_t reply[10] = {5, code, 0, 1};
        [flow.down appendBytes:reply length:sizeof(reply)];
        flow.phase = FCFlowFlushError;
        flow.deadline = monotonicTime() + 5;
    } else {
        flow.phase = FCFlowClosing;
    }
}
- (void)closeFlowSocket:(FCForwardFlow *)flow {
    if (flow.socket >= 0) {
        close(flow.socket);
        flow.socket = -1;
    }
}
- (BOOL)startLocalRule:(FCForwardRule *)rule {
    struct sockaddr_storage address;
    socklen_t length;
    numericAddress(rule.configuration[@"bind"], [rule.configuration[@"port"] integerValue], &address, &length);
    int fd = socket(address.ss_family, SOCK_STREAM, 0);
    if (fd < 0)
        return NO;
    prepareSocket(fd);
    if (address.ss_family == AF_INET6) {
        int one = 1;
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one));
    }
    // Do not reuse a port owned by another listener, or silently pick a different port.
    if (bind(fd, (void *)&address, length) || listen(fd, 16) || getsockname(fd, (void *)&address, &length)) {
        close(fd);
        return NO;
    }
    rule.socket = fd;
    rule.port = ntohs(address.ss_family == AF_INET ? ((struct sockaddr_in *)&address)->sin_port
                                                   : ((struct sockaddr_in6 *)&address)->sin6_port);
    return YES;
}
- (void)acceptLocalRule:(FCForwardRule *)rule {
    for (int batch = 0; batch < 4 && _forwardFlows.count < 64; batch++) {
        struct sockaddr_storage peer;
        socklen_t length = sizeof(peer);
        int fd = accept(rule.socket, (void *)&peer, &length);
        if (fd < 0)
            break;
        prepareSocket(fd);
        FCForwardFlow *flow = [FCForwardFlow new];
        flow.rule = rule;
        flow.socket = fd;
        flow.socks = [rule.kind isEqual:@"socks"];
        flow.phase = flow.socks ? FCFlowGreeting : FCFlowOpening;
        flow.host = rule.configuration[@"host"];
        flow.port = [rule.configuration[@"destinationPort"] integerValue];
        char name[NI_MAXHOST], service[NI_MAXSERV];
        if (!getnameinfo((void *)&peer, length, name, sizeof(name), service, sizeof(service),
                         NI_NUMERICHOST | NI_NUMERICSERV)) {
            flow.origin = @(name);
            flow.originPort = atoi(service);
        } else {
            flow.origin = @"127.0.0.1";
        }
        [_forwardFlows addObject:flow];
    }
}
- (void)resolveDestination:(FCForwardFlow *)flow {
    // DNS never blocks the SSH worker. Completion is keyed to the unique flow ID.
    NSString *identifier = flow.identifier, *host = flow.host, *port = @(flow.port).stringValue;
    [_lock lock];
    _forwardResolutions[identifier] = NSNull.null;
    [_lock unlock];
    __weak FCSSHClient *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      struct addrinfo hints = {0}, *addresses = NULL;
      hints.ai_family = AF_UNSPEC;
      hints.ai_socktype = SOCK_STREAM;
      NSMutableArray *result = [NSMutableArray new];
      if (!getaddrinfo(host.UTF8String, port.UTF8String, &hints, &addresses)) {
          for (struct addrinfo *a = addresses; a && result.count < 16; a = a->ai_next)
              if ((a->ai_family == AF_INET || a->ai_family == AF_INET6) &&
                  a->ai_addrlen <= sizeof(struct sockaddr_storage))
                  [result addObject:[NSData dataWithBytes:a->ai_addr length:a->ai_addrlen]];
          freeaddrinfo(addresses);
      }
      FCSSHClient *client = weakSelf;
      if (!client)
          return;
      [client->_lock lock];
      if (!atomic_load(&client->_stopped) && client->_forwardResolutions[identifier])
          client->_forwardResolutions[identifier] = result;
      [client->_lock unlock];
    });
}
- (void)connectFlow:(FCForwardFlow *)flow {
    if (flow.socket >= 0) {
        struct pollfd pending = {flow.socket, POLLOUT, 0};
        if (poll(&pending, 1, 0) <= 0)
            return;
        int error = 0;
        socklen_t length = sizeof(error);
        if (!getsockopt(flow.socket, SOL_SOCKET, SO_ERROR, &error, &length) && !error) {
            flow.phase = FCFlowStreaming;
            return;
        }
        [self closeFlowSocket:flow];
    }
    while (flow.addressIndex < flow.addresses.count) {
        NSData *data = flow.addresses[flow.addressIndex++];
        const struct sockaddr *address = data.bytes;
        flow.socket = socket(address->sa_family, SOCK_STREAM, 0);
        if (flow.socket < 0)
            continue;
        prepareSocket(flow.socket);
        int result = connect(flow.socket, address, (socklen_t)data.length);
        if (!result) {
            flow.phase = FCFlowStreaming;
            return;
        }
        if (errno == EINPROGRESS)
            return;
        [self closeFlowSocket:flow];
    }
    [self failFlow:flow code:5 message:@"A local destination could not be reached."];
}
- (void)readSOCKS:(FCForwardFlow *)flow {
    uint8_t buffer[1024];
    ssize_t count = recv(flow.socket, buffer, sizeof(buffer) - flow.up.length, 0);
    if (count > 0)
        [flow.up appendBytes:buffer length:count];
    else if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
        flow.phase = FCFlowClosing;
        return;
    }
    const uint8_t *bytes = flow.up.bytes;
    if (flow.phase == FCFlowGreeting && flow.up.length >= 2) {
        NSUInteger methods = bytes[1];
        if (bytes[0] != 5 || methods == 0) {
            flow.phase = FCFlowClosing;
            return;
        }
        if (flow.up.length < methods + 2)
            return;
        BOOL accepted = memchr(bytes + 2, 0, methods) != NULL;
        uint8_t reply[] = {5, accepted ? 0 : 255};
        [flow.down appendBytes:reply length:2];
        consume(flow.up, methods + 2);
        flow.phase = accepted ? FCFlowRequest : FCFlowFlushError;
        if (!accepted) {
            flow.deadline = monotonicTime() + 5;
            return;
        }
        bytes = flow.up.bytes;
    }
    if (flow.phase != FCFlowRequest || flow.up.length < 4)
        return;
    uint8_t error = bytes[0] != 5 || bytes[2] != 0 ? 1 : bytes[1] != 1 ? 7 : 0;
    NSUInteger addressLength = bytes[3] == 1 ? 4 : bytes[3] == 4 ? 16 : 0, offset = 4;
    if (bytes[3] == 3) {
        if (flow.up.length < 5)
            return;
        addressLength = bytes[4];
        offset = 5;
        if (!addressLength)
            error = 8;
    } else if (!addressLength)
        error = 8;
    if (error) {
        flow.phase = FCFlowOpening;
        [self failFlow:flow code:error message:@"A proxy request was invalid or unsupported."];
        return;
    }
    if (flow.up.length < offset + addressLength + 2)
        return;
    char host[INET6_ADDRSTRLEN];
    if (bytes[3] == 3)
        flow.host = [[NSString alloc] initWithBytes:bytes + offset length:addressLength encoding:NSUTF8StringEncoding];
    else {
        inet_ntop(bytes[3] == 1 ? AF_INET : AF_INET6, bytes + offset, host, sizeof(host));
        flow.host = @(host);
    }
    flow.port = ((NSInteger)bytes[offset + addressLength] << 8) | bytes[offset + addressLength + 1];
    consume(flow.up, offset + addressLength + 2);
    flow.phase = FCFlowOpening;
    if (!validDestination(flow.host, flow.port))
        [self failFlow:flow code:8 message:@"A proxy destination was invalid."];
}
- (BOOL)openForwardFlow:(FCForwardFlow *)flow {
    _forwardOpening = flow;
    LIBSSH2_CHANNEL *channel = libssh2_channel_direct_tcpip_ex(_workerSession, flow.host.UTF8String, (int)flow.port,
                                                               flow.origin.UTF8String, (int)flow.originPort);
    if (!channel && libssh2_session_last_errno(_workerSession) == LIBSSH2_ERROR_EAGAIN) {
        [self captureForwardWait];
        if (monotonicTime() >= flow.deadline) {
            flow.rule.message = @"A tunnel channel timed out. Reconnect SSH.";
            _forwardFailure = flow.rule.message;
            [self disconnect];
            return NO;
        }
        return YES;
    }
    _forwardOpening = nil;
    if (!channel) {
        [self failFlow:flow code:5 message:@"The server refused a destination or forwarding is not permitted."];
        return YES;
    }
    flow.channel = channel;
    if (!flow.rule.wanted || flow.phase == FCFlowClosing) {
        flow.phase = FCFlowClosing;
        return YES;
    }
    flow.phase = FCFlowStreaming;
    if (flow.socks) {
        // libssh2 does not expose the server's destination socket address.
        // Report an unspecified bound endpoint, never a fabricated listener address.
        uint8_t reply[10] = {5, 0, 0, 1};
        [flow.down appendBytes:reply length:sizeof(reply)];
    }
    return YES;
}
- (BOOL)advanceRemoteListener:(FCForwardRule *)rule {
    _forwardListening = rule;
    int port = 0;
    rule.listener = libssh2_channel_forward_listen_ex(_workerSession, [rule.configuration[@"bind"] UTF8String],
                                                      [rule.configuration[@"port"] intValue], &port, 16);
    if (!rule.listener && libssh2_session_last_errno(_workerSession) == LIBSSH2_ERROR_EAGAIN) {
        [self captureForwardWait];
        if (monotonicTime() > rule.deadline) {
            _forwardFailure = @"An SSH tunnel listener request timed out. Reconnect SSH.";
            [self disconnect];
            return NO;
        }
        return YES;
    }
    _forwardListening = nil;
    rule.port = rule.listener ? port : 0;
    rule.state = rule.listener ? (rule.wanted ? @"listening" : @"stopping") : @"failed";
    if (!rule.listener) {
        rule.wanted = NO;
        rule.message = @"The server refused the remote listener. Check forwarding policy and port availability.";
    }
    return YES;
}
- (NSUInteger)bufferedForwardBytes {
    NSUInteger total = 0;
    for (FCForwardFlow *flow in _forwardFlows)
        total += flow.up.length + flow.down.length;
    return total;
}
- (void)pumpFlow:(FCForwardFlow *)flow {
    if (flow.phase == FCFlowGreeting || flow.phase == FCFlowRequest)
        [self readSOCKS:flow];
    if (flow.phase == FCFlowResolving) {
        [_lock lock];
        id resolved = _forwardResolutions[flow.identifier];
        [_lock unlock];
        if ([resolved isKindOfClass:NSArray.class]) {
            [_lock lock];
            [_forwardResolutions removeObjectForKey:flow.identifier];
            [_lock unlock];
            flow.addresses = resolved;
            flow.phase = FCFlowConnecting;
        }
    }
    if (flow.phase == FCFlowConnecting)
        [self connectFlow:flow];
    if (flow.phase != FCFlowStreaming && flow.phase != FCFlowFlushError && monotonicTime() > flow.deadline &&
        _forwardOpening != flow)
        [self failFlow:flow code:4 message:@"A tunnel connection timed out."];
    if (flow.phase == FCFlowStreaming) {
        uint8_t buffer[32768];
        NSUInteger remaining = aggregateLimit - MIN(aggregateLimit, [self bufferedForwardBytes]);
        NSUInteger available = MIN(sizeof(buffer), MIN(bufferLimit - MIN(bufferLimit, flow.up.length), remaining));
        if (!flow.localEOF && available) {
            ssize_t count = recv(flow.socket, buffer, available, 0);
            if (count > 0)
                [flow.up appendBytes:buffer length:count];
            else if (!count)
                flow.localEOF = YES;
            else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
                flow.phase = FCFlowClosing;
        }
        if (!flow.write && flow.up.length)
            flow.write = [flow.up subdataWithRange:NSMakeRange(0, MIN(sizeof(buffer), flow.up.length))];
        if (flow.write) {
            ssize_t count = libssh2_channel_write(flow.channel, flow.write.bytes, flow.write.length);
            if (count > 0) {
                consume(flow.up, count);
                flow.write = nil;
            } else if (count == LIBSSH2_ERROR_EAGAIN)
                [self captureForwardWait];
            else if (count < 0)
                flow.phase = FCFlowClosing;
        }
        remaining = aggregateLimit - MIN(aggregateLimit, [self bufferedForwardBytes]);
        available = MIN(sizeof(buffer), MIN(bufferLimit - MIN(bufferLimit, flow.down.length), remaining));
        if (!flow.remoteEOF && available) {
            ssize_t count = libssh2_channel_read(flow.channel, (char *)buffer, available);
            if (count > 0)
                [flow.down appendBytes:buffer length:count];
            else if (count == LIBSSH2_ERROR_EAGAIN)
                [self captureForwardWait];
            else if (count < 0)
                flow.phase = FCFlowClosing;
            else if (libssh2_channel_eof(flow.channel))
                flow.remoteEOF = YES;
        }
        if (flow.localEOF && !flow.up.length && !flow.sentEOF) {
            int result = libssh2_channel_send_eof(flow.channel);
            if (!result)
                flow.sentEOF = YES;
            else if (result == LIBSSH2_ERROR_EAGAIN)
                [self captureForwardWait];
            else
                flow.phase = FCFlowClosing;
        }
        if (flow.remoteEOF && !flow.down.length && !flow.socketEOF) {
            shutdown(flow.socket, SHUT_WR);
            flow.socketEOF = YES;
        }
    }
    if ((flow.phase == FCFlowStreaming || flow.phase == FCFlowFlushError || flow.phase == FCFlowOpening ||
         flow.phase == FCFlowGreeting || flow.phase == FCFlowRequest) &&
        flow.socket >= 0 && flow.down.length) {
        ssize_t count = send(flow.socket, flow.down.bytes, MIN(32768, flow.down.length), 0);
        if (count > 0)
            consume(flow.down, count);
        else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
            flow.phase = FCFlowClosing;
    }
    if (flow.phase == FCFlowStreaming && flow.sentEOF && flow.socketEOF && !flow.down.length)
        flow.phase = FCFlowClosing;
    if (flow.phase == FCFlowFlushError && (!flow.down.length || monotonicTime() > flow.deadline))
        flow.phase = FCFlowClosing;
    if (flow.phase == FCFlowClosing && _forwardOpening != flow) {
        [self closeFlowSocket:flow];
        if (!flow.closeDeadline)
            flow.closeDeadline = monotonicTime() + 10;
        if (flow.channel) {
            int result = libssh2_channel_free(flow.channel);
            if (result == LIBSSH2_ERROR_EAGAIN) {
                [self captureForwardWait];
                if (monotonicTime() > flow.closeDeadline) {
                    _forwardFailure = @"An SSH tunnel could not finish closing. Reconnect SSH.";
                    [self disconnect];
                }
                return;
            }
            flow.channel = NULL;
        }
        [_lock lock];
        [_forwardResolutions removeObjectForKey:flow.identifier];
        [_lock unlock];
        [_forwardFlows removeObject:flow];
    }
}
- (BOOL)pumpForwarding {
    _forwardWaitDirections = 0;
    if (!_workerSession)
        return YES;
    [_lock lock];
    NSArray *commands = [_forwardCommands copy];
    [_forwardCommands removeAllObjects];
    [_lock unlock];
    for (NSDictionary *command in commands) {
        FCForwardRule *rule = nil;
        for (FCForwardRule *candidate in _forwardRules)
            if ([candidate.identifier isEqual:command[@"id"]]) {
                rule = candidate;
                break;
            }
        NSDictionary *configuration = command[@"configuration"];
        if (configuration && !rule) {
            if (_forwardRules.count < 16) {
                [_forwardRules addObject:[self makeForwardRule:configuration start:[command[@"start"] boolValue]]];
            } else if (self.onForwarding) {
                self.onForwarding(command[@"id"], @"failed", 0, 0,
                                  @"The previous tunnel is still closing. Remove it, wait, then try again.");
            }
            continue;
        }
        if (!rule)
            continue;
        BOOL removing = [command[@"remove"] boolValue];
        BOOL start = [command[@"start"] boolValue];
        if (configuration || removing) {
            rule.replacement = configuration;
            rule.replacementStarts = start;
            rule.removing = removing;
        }
        if (!configuration && !removing && start && !rule.wanted && !rule.listener && rule.socket < 0 &&
            ![rule.state isEqual:@"starting"] && ![rule.state isEqual:@"stopping"] && !rule.removing &&
            !rule.replacement) {
            rule.wanted = YES;
            rule.state = @"starting";
            rule.port = 0;
            rule.message = @"";
            rule.deadline = monotonicTime() + 20;
        } else if (configuration || removing || !start) {
            if (!configuration && !removing && !start)
                rule.replacementStarts = NO;
            rule.wanted = NO;
            rule.state = @"stopping";
            rule.deadline = monotonicTime() + 20;
            if (rule.socket >= 0) {
                close(rule.socket);
                rule.socket = -1;
            }
            for (FCForwardFlow *flow in _forwardFlows)
                if (flow.rule == rule)
                    flow.phase = FCFlowClosing;
        }
    }
    // One pending session-level control request at a time; never replace its arguments on EAGAIN.
    if (_forwardOpening && ![self openForwardFlow:_forwardOpening])
        return NO;
    if (_forwardListening && ![self advanceRemoteListener:_forwardListening])
        return NO;
    for (FCForwardRule *rule in _forwardRules) {
        if ([rule.state isEqual:@"starting"] && !_channelOpenBusy && !_forwardOpening && !_forwardListening) {
            if ([rule.kind isEqual:@"remote"]) {
                if (![self advanceRemoteListener:rule])
                    return NO;
            } else {
                if (![self startLocalRule:rule])
                    rule.message = errno == EADDRINUSE ? @"Port already in use. Choose Auto or another port."
                                                       : @"Could not bind the listener. Check its address and port.";
                rule.state = rule.socket >= 0 ? @"listening" : @"failed";
                if (rule.socket < 0)
                    rule.wanted = NO;
            }
        }
        if (!rule.wanted && rule.listener && !_forwardListening && !_forwardOpening && !_channelOpenBusy) {
            int result = libssh2_channel_forward_cancel(rule.listener);
            if (result == LIBSSH2_ERROR_EAGAIN) {
                [self captureForwardWait];
                if (monotonicTime() > rule.deadline) {
                    _forwardFailure = @"An SSH tunnel listener could not finish stopping. Reconnect SSH.";
                    [self disconnect];
                    return NO;
                }
            } else
                rule.listener = NULL;
        }
        BOOL hasFlows = NO;
        for (FCForwardFlow *flow in _forwardFlows)
            if (flow.rule == rule)
                hasFlows = YES;
        if (!rule.wanted && !rule.listener && rule.socket < 0 && !hasFlows && _forwardListening != rule &&
            ![rule.state isEqual:@"failed"] && ![rule.state isEqual:@"starting"]) {
            rule.state = @"stopped";
            rule.port = 0;
        }
        if (rule.wanted && [rule.state isEqual:@"listening"]) {
            if (rule.socket >= 0)
                [self acceptLocalRule:rule];
            if (rule.listener && _forwardFlows.count < 64) {
                LIBSSH2_CHANNEL *channel = libssh2_channel_forward_accept(rule.listener);
                if (channel) {
                    FCForwardFlow *flow = [FCForwardFlow new];
                    flow.rule = rule;
                    flow.channel = channel;
                    flow.host = rule.configuration[@"host"];
                    flow.port = [rule.configuration[@"destinationPort"] integerValue];
                    flow.phase = FCFlowResolving;
                    [_forwardFlows addObject:flow];
                    [self resolveDestination:flow];
                } else if (libssh2_session_last_errno(_workerSession) == LIBSSH2_ERROR_EAGAIN)
                    [self captureForwardWait];
            }
        }
    }
    NSArray *flows = [_forwardFlows copy];
    // Rotate the starting point; each connection gets one bounded I/O slice.
    for (NSUInteger index = 0; index < MIN(8, flows.count); index++) {
        FCForwardFlow *flow = flows[(index + _forwardCursor) % flows.count];
        if (flow.phase == FCFlowOpening && !_forwardOpening && !_forwardListening && !_channelOpenBusy &&
            flow.rule.wanted)
            if (![self openForwardFlow:flow])
                return NO;
        [self pumpFlow:flow];
    }
    _forwardCursor += 8;
    for (FCForwardRule *rule in [_forwardRules copy]) {
        BOOL hasFlows = NO;
        for (FCForwardFlow *flow in _forwardFlows)
            if (flow.rule == rule)
                hasFlows = YES;
        if ((rule.removing || rule.replacement) && !rule.listener && rule.socket < 0 && !hasFlows &&
            _forwardListening != rule) {
            if (rule.removing) {
                rule.state = @"removed";
                [self publishRule:rule];
                [_forwardRules removeObject:rule];
                continue;
            }
            rule.configuration = rule.replacement;
            rule.kind = rule.configuration[@"kind"];
            rule.replacement = nil;
            rule.wanted = rule.replacementStarts;
            rule.state = rule.wanted ? @"starting" : @"stopped";
            rule.message = @"";
            rule.port = 0;
            rule.deadline = monotonicTime() + 20;
        }
        [self publishRule:rule];
    }
    return !atomic_load(&_stopped);
}
- (BOOL)serviceInteractive {
    if (_servicingForwarding)
        return YES;
    // Forwarding-only sessions may have no shell/subsystem to notice transport EOF.
    // Peeking leaves encrypted bytes exclusively owned by libssh2.
    if (_socket >= 0) {
        struct pollfd transport = {_socket, POLLIN, 0};
        if (poll(&transport, 1, 0) > 0) {
            uint8_t byte;
            ssize_t count = recv(_socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
            if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
                return NO;
        }
    }
    _servicingForwarding = YES;
    BOOL result = [self pumpTerminal:_workerChannel] && [self pumpForwarding];
    _servicingForwarding = NO;
    return result;
}
- (void)waitForServiceEvents:(short)events timeout:(int)milliseconds {
    struct pollfd descriptors[82];
    nfds_t count = 0;
    int directions = _forwardWaitDirections | _terminalWaitDirections;
    if (directions & LIBSSH2_SESSION_BLOCK_INBOUND)
        events |= POLLIN;
    if (directions & LIBSSH2_SESSION_BLOCK_OUTBOUND)
        events |= POLLOUT;
    descriptors[count++] = (struct pollfd){_socket, events, 0};
    if (_forwardWakeRead >= 0)
        descriptors[count++] = (struct pollfd){_forwardWakeRead, POLLIN, 0};
    if (_forwardFlows.count < 64) {
        for (FCForwardRule *rule in _forwardRules)
            if (rule.socket >= 0)
                descriptors[count++] = (struct pollfd){rule.socket, POLLIN, 0};
    }
    BOOL canRead = [self bufferedForwardBytes] < aggregateLimit;
    for (FCForwardFlow *flow in _forwardFlows) {
        if (flow.socket < 0)
            continue;
        short readiness = 0;
        if (flow.phase == FCFlowGreeting || flow.phase == FCFlowRequest ||
            (flow.phase == FCFlowStreaming && !flow.localEOF && canRead && flow.up.length < bufferLimit))
            readiness |= POLLIN;
        if (flow.phase == FCFlowConnecting || flow.down.length)
            readiness |= POLLOUT;
        if (readiness)
            descriptors[count++] = (struct pollfd){flow.socket, readiness, 0};
    }
    poll(descriptors, count, milliseconds);
    if (_forwardWakeRead >= 0) {
        uint8_t ignored[64];
        while (recv(_forwardWakeRead, ignored, sizeof(ignored), 0) > 0) {
        }
    }
}
- (BOOL)drainForwardOpenUntil:(double)deadline {
    // Before lazy SFTP initialization, finish any generic channel open already in flight.
    while ((_forwardOpening || _forwardListening) && !atomic_load(&_stopped) && monotonicTime() < deadline) {
        if ((_forwardOpening && ![self openForwardFlow:_forwardOpening]) ||
            (_forwardListening && ![self advanceRemoteListener:_forwardListening]) ||
            ![self pumpTerminal:_workerChannel])
            return NO;
        struct pollfd pending = {_socket, POLLIN | POLLOUT, 0};
        poll(&pending, 1, 10);
    }
    if (_forwardOpening || _forwardListening) {
        [self disconnect];
        return NO;
    }
    return !atomic_load(&_stopped);
}
- (void)cleanupForwarding {
    for (FCForwardRule *rule in _forwardRules) {
        if (rule.socket >= 0)
            close(rule.socket);
        rule.socket = -1;
        rule.wanted = NO;
        rule.state = @"stopped";
        rule.port = 0;
        // Session teardown frees library listeners/channels after transport interruption.
        rule.listener = NULL;
    }
    for (FCForwardFlow *flow in _forwardFlows)
        [self closeFlowSocket:flow];
    [_forwardFlows removeAllObjects];
    _forwardOpening = nil;
    _forwardListening = nil;
    [_lock lock];
    [_forwardResolutions removeAllObjects];
    [_forwardCommands removeAllObjects];
    [_lock unlock];
    for (FCForwardRule *rule in _forwardRules)
        [self publishRule:rule];
}
@end
