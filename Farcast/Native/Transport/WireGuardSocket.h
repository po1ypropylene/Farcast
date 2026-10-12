#pragma once
#import <Foundation/Foundation.h>
#import <errno.h>
#import <poll.h>
#import <sys/socket.h>
#import <time.h>

// Shared helper wire protocol for TCP adapters. The caller owns dialing and closing
// the socket, and retains the original destination for protocol identity checks.
static inline NSString *FCWireGuardSocketFailure(unsigned char code) {
    switch (code) {
    case 2:
        return @"Enter DNS servers in the WireGuard profile or use the private server IP address. No direct "
               @"connection was attempted.";
    case 3:
        return @"The configured WireGuard DNS servers could not resolve the server. Check DNS or use the private "
               @"server IP address. No direct connection was attempted.";
    case 4:
        return @"The destination is outside the WireGuard profile’s AllowedIPs. Check the private server address "
               @"and tunnel routes. No direct connection was attempted.";
    default:
        return @"WireGuard could not reach the private server. Check the peer, keys, server routing and firewall. "
               @"No direct connection was attempted.";
    }
}

static inline int FCWireGuardHexDigit(unichar digit) {
    if (digit >= '0' && digit <= '9')
        return digit - '0';
    if (digit >= 'a' && digit <= 'f')
        return digit - 'a' + 10;
    if (digit >= 'A' && digit <= 'F')
        return digit - 'A' + 10;
    return -1;
}

static inline double FCWireGuardSocketTime(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

// Worker-only, bounded and cancellable. No SSH/TLS bytes are sent until the helper
// authenticates the token and confirms that its encrypted destination is open.
static inline BOOL FCWireGuardAuthenticateSocket(int fd, NSString *token, BOOL (^cancelled)(void), NSString **failure) {
    *failure = FCWireGuardSocketFailure(0);
    if (fd < 0 || token.length != 64)
        return NO;
    unsigned char bytes[32];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) {
        int high = FCWireGuardHexDigit([token characterAtIndex:i * 2]);
        int low = FCWireGuardHexDigit([token characterAtIndex:i * 2 + 1]);
        if (high < 0 || low < 0)
            return NO;
        bytes[i] = (unsigned char)((high << 4) | low);
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    double deadline = FCWireGuardSocketTime() + 30;
    size_t sent = 0;
    while (!cancelled() && FCWireGuardSocketTime() < deadline) {
        BOOL writing = sent < sizeof(bytes);
        struct pollfd pending = {fd, writing ? POLLOUT : POLLIN, 0};
        int ready = poll(&pending, 1, 100);
        if (ready == 0 || (ready < 0 && errno == EINTR))
            continue;
        if (ready < 0 || (pending.revents & POLLNVAL))
            return NO;
        unsigned char reply = 0;
        ssize_t count =
            writing ? send(fd, bytes + sent, sizeof(bytes) - sent, MSG_DONTWAIT) : recv(fd, &reply, 1, MSG_DONTWAIT);
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
            continue;
        if (count <= 0)
            return NO;
        if (writing) {
            sent += (size_t)count;
        } else {
            if (reply == 1) {
                *failure = nil;
                return !cancelled();
            }
            *failure = FCWireGuardSocketFailure(reply);
            return NO;
        }
    }
    return NO;
}
