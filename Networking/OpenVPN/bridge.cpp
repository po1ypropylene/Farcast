// Farcast's app-private adapter. OpenVPN Core owns protocol and TLS processing.
#include "bridge.h"
#include <atomic>
#include <client/ovpncli.hpp>
#include <unistd.h>

namespace {
class Client final : public openvpn::ClientAPI::OpenVPNClient {
  public:
    int fd;
    std::atomic<int> state{0}; // 0 starting, 1 connected, -1 stopped/failed
    std::atomic<bool> cancelled{false};
    std::string addresses, dns, routes;
    int mtu = 1500;
    explicit Client(int packetFD) : fd(packetFD) {}
    ~Client() override { close(fd); }
    static void append(std::string &out, const std::string &entry) {
        if (!out.empty())
            out += ',';
        out += entry;
    }
    bool tun_builder_new() override {
        // Reconnect must acquire a new app lease and network stack.
        if (state.load() != 0)
            return false;
        addresses.clear();
        dns.clear();
        routes.clear();
        return true;
    }
    bool tun_builder_set_layer(int layer) override { return layer == 3; }
    bool tun_builder_set_remote_address(const std::string &, bool) override { return true; }
    bool tun_builder_add_address(const std::string &address, int prefix, const std::string &, bool, bool) override {
        append(addresses, address + "/" + std::to_string(prefix));
        return true;
    }
    bool tun_builder_add_route(const std::string &address, int prefix, int, bool) override {
        append(routes, address + "/" + std::to_string(prefix));
        return true;
    }
    bool tun_builder_reroute_gw(bool v4, bool v6, unsigned int) override {
        if (v4)
            append(routes, "0.0.0.0/0");
        if (v6)
            append(routes, "::/0");
        return true;
    }
    // Exclusion semantics must never be silently ignored.
    bool tun_builder_exclude_route(const std::string &, int, int, bool) override { return false; }
    bool tun_builder_set_route_metric_default(int) override { return true; }
    bool tun_builder_set_dns_options(const openvpn::DnsOptions &options) override {
        for (const auto &[priority, server] : options.servers) {
            if (server.dnssec == openvpn::DnsServer::Security::Yes ||
                (server.transport != openvpn::DnsServer::Transport::Unset &&
                 server.transport != openvpn::DnsServer::Transport::Plain))
                return false;
            for (const auto &address : server.addresses) {
                if (address.port != 0 && address.port != 53)
                    return false;
                append(dns, address.address);
            }
        }
        return true;
    }
    bool tun_builder_set_mtu(int value) override {
        if (value < 1280 || value > 1500)
            return false;
        mtu = value;
        return true;
    }
    bool tun_builder_set_session_name(const std::string &) override { return true; }
    bool tun_builder_set_allow_family(int, bool) override { return true; }
    int tun_builder_establish() override { return dup(fd); }
    bool pause_on_connection_timeout() override { return false; }
    void log(const openvpn::ClientAPI::LogInfo &) override {} // Never emit profile or credential data.
    void acc_event(const openvpn::ClientAPI::AppCustomControlMessageEvent &) override {}
    void event(const openvpn::ClientAPI::Event &event) override {
        if (event.name == "CONNECTED")
            state.store(1);
        else if (event.fatal || event.error || event.name == "RECONNECTING" || event.name == "DISCONNECTED") {
            state.store(-1);
            stop();
        }
    }
    void clock_tick() override {
        if (cancelled.load())
            stop();
    }
    void external_pki_cert_request(openvpn::ClientAPI::ExternalPKICertRequest &request) override {
        request.error = true;
    }
    void external_pki_sign_request(openvpn::ClientAPI::ExternalPKISignRequest &request) override {
        request.error = true;
    }
};
} // namespace
extern "C" {
void *farcast_ovpn_create(const char *profile, const char *username, const char *password, const char *passphrase,
                          int fd) {
    try {
        auto client = std::make_unique<Client>(fd);
        openvpn::ClientAPI::Config config;
        config.content = profile;
        config.disableClientCert = config.content.find("<cert>") == std::string::npos;
        config.connTimeout = 30;
        config.clockTickMS = 100;
        config.compressionMode =
            config.content.find("setenv FARCAST_LEGACY_COMPRESSION 1") != std::string::npos ? "asym" : "no";
        config.privateKeyPassword = passphrase;
        config.allowUnusedAddrFamilies = "no";
        const auto evaluated = client->eval_config(config);
        if (evaluated.error || evaluated.externalPki)
            return nullptr;
        openvpn::ClientAPI::ProvideCreds credentials;
        credentials.username = username;
        credentials.password = password;
        if (client->provide_creds(credentials).error)
            return nullptr;
        return client.release();
    } catch (...) {
        return nullptr;
    }
}
void farcast_ovpn_run(void *p) {
    auto *client = static_cast<Client *>(p);
    try {
        if (!client->cancelled.load())
            client->connect();
    } catch (...) {
    }
    client->state.store(-1);
}
void farcast_ovpn_stop(void *p) {
    auto *client = static_cast<Client *>(p);
    client->cancelled.store(true);
    client->stop();
}
int farcast_ovpn_state(void *p) { return static_cast<Client *>(p)->state.load(); }
const char *farcast_ovpn_addresses(void *p) { return static_cast<Client *>(p)->addresses.c_str(); }
const char *farcast_ovpn_dns(void *p) { return static_cast<Client *>(p)->dns.c_str(); }
const char *farcast_ovpn_routes(void *p) { return static_cast<Client *>(p)->routes.c_str(); }
int farcast_ovpn_mtu(void *p) { return static_cast<Client *>(p)->mtu; }
void farcast_ovpn_free(void *p) { delete static_cast<Client *>(p); }
}
