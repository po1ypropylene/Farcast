# SSH, RDP and VNC through embedded WireGuard

## Set up

1. Open **File → VPN Connections…**, or **Add → WireGuard Connections…**.
   The connection editor also has **Manage WireGuard Connections…**.
2. Choose **New**. Import your WireGuard `.conf` file, or enter a name, interface
   address/prefix, private key, peer public key, endpoint, and Allowed IPs. Add a
   preshared key if your server requires one. Save.
3. Add or edit an **SSH, RDP or VNC** connection. Enter the server's private IP address or
   its internal DNS name as **Address**, with its normal protocol port.
4. Choose the saved profile under **General → Network → Connect via**, then **Save & Connect**.
   The app establishes the encrypted path automatically before the selected protocol negotiates.
   Verify any SSH host-key or RDP/VNC certificate prompt against your administrator's fingerprint,
   as with a direct connection.

You can keep several named WireGuard profiles. **Direct** is
an explicit selection; a missing/deleted profile or tunnel failure never selects
it automatically. Deleting a WireGuard profile leaves references in connection profiles
unresolved so they refuse to connect. Edit those connection profiles to choose a valid
profile or deliberately select Direct. Active sessions retain their configuration
until disconnected. Reconnect loads the current connection and WireGuard settings.

## Configuration details

- One Interface and one Peer per WireGuard profile. Comma-separated IPv4/IPv6
  addresses and AllowedIPs use CIDR prefixes, for example `10.0.0.2/32` and
  `10.0.0.0/24`. An IPv6 peer endpoint uses `[address]:port`.
- DNS is optional and contains IP addresses, not search domains. Internal server
  names resolve through the explicitly configured servers. DNS servers covered
  by AllowedIPs use WireGuard; other configured DNS servers use the Mac's normal
  network, matching split routes. This can send hostname queries to a configured
  public resolver. It never changes system DNS settings. Literal server IP addresses
  skip DNS entirely. The destination IP must be covered by AllowedIPs, with
  no direct fallback. The public WireGuard peer hostname resolves using the
  Mac's normal resolver before starting the tunnel.
- MTU is 1280–1500 (default 1420). Keepalive is 0–65535 seconds (default 25);
  zero disables persistent keepalives. ListenPort in an import is accepted but
  ignored: the app chooses its own ephemeral UDP port. Scripts, extra settings,
  duplicate fields, and multiple peers are rejected with a redacted error.
- The server must allow outbound UDP to the WireGuard endpoint and route/permit
  the configured peer address to the private server. The app does not change
  the server's routing/firewall. RDP UDP multitransport is disabled on this path;
  the existing desktop, input, clipboard and audio channels continue over TCP.
- SSH, RDP and VNC tabs using the same saved profile share one encrypted device with independent
  destination connections. Disconnecting one tab leaves the others connected.
  Disconnect all sessions using a profile before applying edited keys/settings.
  Do not create separate profiles with the same private key for simultaneous use,
  or use that same WireGuard identity concurrently in an external VPN client:
  competing endpoints can disrupt connectivity at the server.

## Privacy and lifecycle

No WireGuard installation, administrator access, NetworkExtension, system TUN,
macOS VPN profile, system routes or system DNS changes are needed. Only the app's
selected sessions use the userspace stack. Direct sessions and other applications
retain their existing networking.

SwiftData stores configuration metadata and profile IDs. Private/preshared keys
use the app's existing Keychain credential store and its disclosed development
fallback (owner-only, unencrypted local files). Imported configuration files
remain untouched and can contain plaintext keys; protect or remove the original
file yourself after saving. Import never executes scripts or connects.

The bundled helper receives keys/configuration through an anonymous input pipe,
never command arguments or temporary configuration files. A separate random
256-bit token protects each loopback-only ephemeral listener. Each token forwards
only its selected host/port; it is not a SOCKS or general proxy. Closing a session
cancels its listener, handshake and sockets. The last session closes the helper;
parent exit/EOF and termination signals also close its device/listeners. Failures
are redacted, with no direct fallback. SSH host-key trust and RDP TLS/NLA and VNC TLS use the **original** host/port;
server redirection to a different endpoint is refused on the tunneled path.

## Build and verification

Go 1.27+ is a developer build requirement; the shipped app requires no Go runtime
installation. Normal dependency preparation/build scripts include the helper.
For an Xcode build after source changes, first run scripts/prepare-wireguard.sh.
The helper is nested-signed to inherit the app's sandbox. The app grants incoming
and outgoing socket permissions for WireGuard UDP and the loopback bridge; no
system VPN permission is involved. Final bundle verification checks those rights
and runs a synthetic helper startup/cleanup probe from the signed app, alongside
the arm64/macOS 27 signature/dependency/loader checks.
Licenses and the module inventory ship under Resources/ThirdParty.

```sh
scripts/test-wireguard.sh
scripts/test-wireguard-rdp.sh
scripts/test-wireguard-sessions.sh
scripts/test-wireguard-lifecycle.sh
scripts/test-wireguard-migration.sh
```

Tests use generated disposable keys, loopback UDP peers, userspace IP addresses,
synthetic SSH/SFTP and RDP servers and isolated storage. They do not use the protected real-server
file, system VPN settings, the user's clipboard or persistent profiles.

Endpoint DNS refreshes on manual reconnect, not periodically while connected.
Production interoperability and release checks are tracked in [validation](validation.md).

Startup failures distinguish invalid configuration, unresolved peer endpoint,
missing/unlaunchable helper, initialization failure, listener failure and timeout.
During server connection, errors distinguish missing DNS, failed DNS, a destination
outside AllowedIPs and an unreachable private server. These messages contain no
configuration values, keys or server identifiers.
