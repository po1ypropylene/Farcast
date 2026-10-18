#pragma once
#ifdef __cplusplus
extern "C" {
#endif
void *farcast_ovpn_create(const char *profile, const char *username, const char *password, const char *passphrase,
                          int packet_fd);
void farcast_ovpn_run(void *client);
void farcast_ovpn_stop(void *client);
int farcast_ovpn_state(void *client);
const char *farcast_ovpn_addresses(void *client);
const char *farcast_ovpn_dns(void *client);
const char *farcast_ovpn_routes(void *client);
int farcast_ovpn_mtu(void *client);
void farcast_ovpn_free(void *client);
#ifdef __cplusplus
}
#endif
