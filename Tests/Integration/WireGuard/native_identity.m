// Exercise the real adapter's transport hook without a remote server.
#import "../../../Farcast/Native/RDP/RDPClient.m"
static int peer = -1;
static int calls = 0;
static BYTE reply = 1;
static int fakeConnect(rdpContext *context, rdpSettings *settings, const char *hostname, int port, DWORD timeout) {
    calls++;
    if (strcmp(hostname, "127.0.0.1") || port != 45678 ||
        strcmp(freerdp_settings_get_string(settings, FreeRDP_ServerHostname), "private.example") ||
        freerdp_settings_get_uint32(settings, FreeRDP_ServerPort) != 3389)
        return -1;
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair))
        return -1;
    peer = pair[1];
    BYTE ack = reply;
    write(peer, &ack, 1);
    return pair[0];
}
int main(void) {
    @autoreleasepool {
        FCRDPClient *client = [FCRDPClient new];
        client.tunnelPort = 45678;
        client.tunnelToken = [@"" stringByPaddingToLength:64 withString:@"ab" startingAtIndex:0];
        RDP_CLIENT_ENTRY_POINTS ep = {0};
        ep.Size = sizeof(ep);
        ep.Version = RDP_CLIENT_INTERFACE_VERSION;
        ep.ContextSize = sizeof(FCContext);
        ep.ClientNew = clientNew;
        rdpContext *context = freerdp_client_context_new(&ep);
        if (!context)
            return 1;
        FCContext *ctx = (FCContext *)context;
        ctx->owner = (__bridge void *)client;
        ctx->identityHost = "private.example";
        ctx->identityPort = 3389;
        ctx->directTCPConnect = fakeConnect;
        freerdp_settings_set_string(context->settings, FreeRDP_ServerHostname, "private.example");
        freerdp_settings_set_uint32(context->settings, FreeRDP_ServerPort, 3389);
        BOOL pass = tunnelTCPConnect(context, context->settings, "other.example", 3389, 1000) < 0 && calls == 0;
        pass = pass && tunnelTCPConnect(context, context->settings, "private.example", 3390, 1000) < 0 && calls == 0;
        int fd = tunnelTCPConnect(context, context->settings, "private.example", 3389, 1000);
        BYTE token[32];
        pass = pass && fd >= 0 && calls == 1 && read(peer, token, sizeof(token)) == 32;
        for (int i = 0; i < 32; i++)
            pass = pass && token[i] == 0xab;
        if (fd >= 0)
            close(fd);
        if (peer >= 0)
            close(peer);
        for (BYTE code = 2; code <= 5; code++) {
            reply = code;
            client.tunnelFailure = nil;
            int refused = tunnelTCPConnect(context, context->settings, "private.example", 3389, 1000);
            pass = pass && refused < 0 && client.tunnelFailure.length > 0 &&
                   [client.tunnelFailure rangeOfString:@"private.example"].location == NSNotFound;
            if (refused >= 0)
                close(refused);
            if (peer >= 0)
                close(peer);
        }
        // The shared primitive refuses malformed tokens/cancellation before
        // sending bytes, and handles a closed helper socket without SIGPIPE.
        int pair[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair))
            return 1;
        NSString *failure = nil;
        NSString *invalid = [@"" stringByPaddingToLength:64 withString:@"az" startingAtIndex:0];
        pass = pass && !FCWireGuardAuthenticateSocket(
                           pair[0], invalid,
                           ^BOOL {
                             return NO;
                           },
                           &failure);
        pass = pass && failure.length > 0;
        pass = pass && !FCWireGuardAuthenticateSocket(
                           pair[0], client.tunnelToken,
                           ^BOOL {
                             return YES;
                           },
                           &failure);
        struct pollfd pending = {pair[1], POLLIN, 0};
        pass = pass && poll(&pending, 1, 0) == 0;
        close(pair[1]);
        pass = pass && !FCWireGuardAuthenticateSocket(
                           pair[0], client.tunnelToken,
                           ^BOOL {
                             return NO;
                           },
                           &failure);
        close(pair[0]);
        freerdp_client_context_free(context);
        printf("%s RDP tunnel hook: real TLS/NLA identity, authenticated socket, redirection refused\n",
               pass ? "PASS" : "FAIL");
        return pass ? 0 : 1;
    }
}
