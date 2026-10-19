# Validation and known limits

Use [testing](testing.md) for commands and fixture details. The coverage below
identifies reproducible checks, not a pass record for the current checkout.
Run the relevant suites after changes. Synthetic results establish only their
stated scope; disabled live entries report SKIP.

## Automated coverage

| Area | Checks | Evidence boundary |
| --- | --- | --- |
| Core and persistence | Sidebar rename/reopen identity, collapse state and retained legacy favorite metadata; draft validation, credential encoding/permissions, endpoint trust, imports, prompt cancellation, display geometry and resize coordination | Isolated stores and synthetic input |
| Migration | Old-module and pre-feature SwiftData stores, ID/metadata preservation, credential opt-in, reopening and unchanged source bytes | Disposable libraries; user-container grants need live testing |
| SSH/SFTP | Authentication/trust, fresh sign-in retry, file-only fallback, byte equality, overwrite/move safety, cancellation, terminal scheduling and throughput; navigation history, cache hits/expiry/eviction/invalidation, stale replies and filename filtering | Loopback peers, controlled proxies and explicit synthetic listing replies |
| SSH forwarding | Local/remote/SOCKS byte equality, live add/edit/remove including initially empty sessions, concurrency, IPv6, server-only DNS, malformed/fragmented messages, backpressure and EOF, policy denial, ports, stop/restart, forwarding-only sessions, file conflicts/cancellation, WireGuard sharing/reconnect/failure and signed sandboxed listeners | Owned loopback/encrypted peers and native off-screen controls; production policy and throughput unverified |
| VNC | RFB versions/security, DES challenge, TLS trust/refusal, raw/CopyRect/Hextile/Zlib/resize, Unicode key pairs, pointer, typing cancellation and malformed input | Owned synthetic peers; production interoperability is unverified |
| RDP channels | TLS/NLA, frames, clipboard text/files, folder drives, Display Control PDUs, initial monitor attributes and pointer input | Synthetic peers; channel submission does not prove Windows acceptance |
| RDP recovery | Idle worker health, stalled-worker interruption, abrupt peer loss, visible stale/failed/reconnecting state, three-attempt backoff, cancellation, teardown ordering, callback generations and same-tab TLS reauthentication | Owned TLS peer and controlled native callbacks; production long-session failure reproduction remains pending |
| RDP folder browsing | Packed directory formats, compatibility padding at enumeration end, Unicode pagination, trailing separators and nested files; direct/WireGuard fixtures | Signed app on one authorized Windows server with direct transport: complete visible root count and repeated browsing through two subfolder levels. Real writes and other server policies remain unverified |
| RDP presentation | Cropped Metal uploads, inverse input mapping, letterbox/stale-frame rejection, full-screen startup/exit/re-entry and teardown; resize opt-in overrides all stored display modes and repeated pop-out/resize/close returns converge on server geometry with Retina on/off against an owned Display Control peer | Marked frames and owned off-screen windows |
| Workspace | Overlay/pinned connection-details viewport geometry and surface identity in attached/detached windows, persisted pin preference; tab ordering/reconnect, detached surface ownership, focus/prompt routing, terminal menus, deferred connection/tunnel validation, centered empty/stopped tunnel layouts at narrow/wide sizes in light/dark, template type selection, view-specific terminal tools, conditional Disconnect All and AppKit shutdown | Synthetic sessions, private pasteboards and preferences |
| Connection status | Inspector failure retention, VPN lifecycle activity, initial/submitted/observed RDP geometry and resize fallback events; shared sidebar/tab/status-bar colours across all session states in light/dark; per-session VPN startup, readiness, failure, release and recovery while other sessions share the helper | Owned native windows and encrypted loopback peers; VPN Ready indicates an available destination lease, not continuous peer-health verification |
| VPN editor and Settings | Field validation and engine bounds, initial selection, dirty/Cancel/Revert/Save, secure-field controls, import summaries and grouped Settings in light/dark | Synthetic credentials and owned native windows; full VoiceOver and Finder drops need manual verification |
| OpenVPN | Safe profile import, credential coding, ZIP/folder/manual companion import, UDP/TCP TLS negotiation, legacy AES-CBC/LZO framing, encrypted outbound IP delivery, certificate rejection, shared leases, route refusal and cancellation against an owned null-device peer | Synthetic certificates only; production interoperability and full desktop/file traffic remain unverified |
| WireGuard | Encrypted loopback traffic, concurrent SSH/SFTP/RDP/VNC on one helper, independent disconnect/reconnect, DNS/route and host-key refusal, shared-helper failure/cleanup and schema migration | Generated keys and owned peers |
| Packaging/signing | Platform, library closure, signatures, loader, sandboxed helper, certificate continuity, mounted bundle and SHA256 | Local development artifact; distribution is separate |
| Maintenance | Cleanup boundaries, dependency rollback, signing policy, harness teardown and repository hygiene | Disposable files and mocked destructive operations |

## Known implementation limits

- **Keychain:** synchronous operations can block UI callers during authorization
  or unlocking. The local-file fallback cannot help while a call is waiting.
  Moving I/O off the main actor needs an explicit prompt/cancellation policy.
- **RDP display:** software bitmap negotiation supplies Metal frames. Dynamic
  resizing requires server Display Control support; actual received geometry is
  authoritative. Multi-monitor presentation requires matching monitor confirmation.
  Live multi-monitor topology updates are unsupported; hotplug/rotation requires
  reconnecting. Dimension confirmation does not confirm Windows DPI appearance.
- **RDP recovery:** liveness checks detect direct TCP failure and stalled client
  workers, not a frozen remote application that still acknowledges TCP. An unchanged
  desktop alone is not evidence of failure. WireGuard's local socket keepalives do
  not probe the remote peer; recovery begins when its helper/transport reports loss
  or the RDP worker stalls. Retries use fresh authentication and server policy controls
  desktop resumption. Three retries are available after an established session;
  one minute of stable connection resets the budget. OS scheduling and local I/O
  can delay detection or cleanup. Real network blackholes and sleep/wake need live
  validation; the original long-session hang has not been reproduced.
- **RDP input and files:** physical scan codes use the US layout. Consecutive
  pointer moves coalesce; input queue overload disconnects explicitly. Folder redirection
  omits directory notifications, byte-range locking and ACL editing. Clipboard
  batches are temporary, copy-only and limited to 8 GiB / 20,000 entries.
  Remote file offers are current-host-only, excluding Universal Clipboard sync.
  Copy advertises metadata only; delayed file-URL demand starts transfer and
  waits at most five minutes, servicing native events on the main thread. Only
  complete batches become usable URLs. Ownership loss cancels pending batches,
  including a stalled paste; completed batches retain their files. Third-party clipboard consumers that request
  file URLs can trigger fulfillment without a Finder Paste command. Eight-range
  pipelining is covered by synthetic 50 MB
  reordered/short/duplicate-response checks, not a production speed measurement.
  Drive names use terminated UTF-8 for interoperability. ASCII drive names and
  nested browsing have live Windows coverage; Unicode labels and real writes
  still need verification. Streamed listings above 20,000 entries and independent
  cursors, literal bracket filters and queued shutdown cancellation are covered
  locally; one-entry wire replies remain round-trip limited.
  Comparative production directory throughput has not been measured.
- **VNC:** classic password/no-auth has no desktop encryption or server identity;
  use WireGuard on untrusted networks. VeNCrypt requires supported X509 modes.
  ARD/proprietary security, anonymous TLS, file/audio/cursor channels and client
  resolution requests are unsupported. Clipboard typing depends on server Unicode
  keysym handling and cannot retract delivered input. Full screen uses one display.
- **SFTP:** atomic upload replacement requires OpenSSH POSIX rename. Moves require
  quiescent sources; metadata checks cannot detect every concurrent content change.
  Cancellation/failure can leave partial destinations or completed tree leaves.
  Local publication requires hard-link support. Resume and Finder download
  promises are unsupported; remote Open creates a snapshot without automatic upload.
  Cached folder views can lag external changes by up to 30 seconds; Refresh
  bypasses the cache. Cached metadata never substitutes for operation preflight.
- **libssh2:** the app builds a pinned, unreleased master snapshot containing the
  CVE-2026-55200 packet-length bounds fix. Commit ancestry establishes inclusion;
  SSH/SFTP fixtures check app interoperability, not a complete security audit or
  compatibility with every production server. See [dependency provenance](../ThirdParty/README.md).
- **OpenVPN:** supports TUN profiles imported from ZIP/folder bundles or individually selected companion files, with certificate/key or password authentication. Legacy incoming LZO requires explicit consent; outgoing traffic remains uncompressed. Scripts, unresolved external files, TAP, proxies, other compression modes, interactive MFA and route exclusions are unsupported. Orbi desktop TAP bundles are detected; the router’s For Smart Phone TUN export is required. Negotiation failures are redacted. Real VPN services, roaming, sleep/wake, throughput and complete SSH/RDP/VNC traffic over OpenVPN need live validation.
- **WireGuard:** endpoint DNS refreshes on manual reconnect, not periodically.
  Missing profiles, tunnel failures and uncovered destinations fail closed.
- **SSH forwarding:** loopback-only local listeners, SOCKS5 CONNECT without proxy
  authentication, at most 16 rules/64 flows. BIND/UDP, HTTP proxy, Unix-socket
  forwarding and system-proxy setup are unsupported. Server policy determines
  remote binding/cancellation and destination access. Forwarded destinations are
  reached from the SSH server, beyond the WireGuard lease's destination check;
  encryption beyond that server depends on the destination protocol. Active rules
  reduce the SFTP pipeline budget. Production policies, long sessions and complete
  keyboard/VoiceOver workflows remain unverified.
- **Release:** local signing uses a pinned Apple Development certificate with
  hardened runtime disabled. Developer ID distribution, notarization, clean-Mac
  installation and vulnerability/legal review remain pending. Farcast's original
  source is MIT-licensed; bundled dependencies retain separate licenses.
  The development credential fallback is unencrypted.

See [architecture](architecture.md) for ownership, protocol bounds and unsupported
features, and [packaging](packaging.md) for signing requirements.

## Sidebar validation

`scripts/test-sidebar-migration.sh` opens an owned pre-sidebar schema with the
current models, verifies retained profiles and folder IDs, and reopens new collapse
metadata. Core tests cover nested folder metadata, legacy favorite metadata preservation, SSH config first-match defaults, proxy exclusion and input bounds.
The workspace presentation harness renders SSH theme previews at normal and enlarged font sizes
using the terminal renderer and self-contained fictional output.
The workspace presentation harness renders sidebar hierarchy and connection states
using synthetic profiles in light/dark appearances, including configured VPN names
and missing-profile labels in connection subtitles. Protocol-icon previews include
SSH, RDP and VNC together in native selected/unselected lists and session tabs,
with explicit light/dark and Increase Contrast appearances. The icons use adaptive
teal/indigo/orange shades and semibold strokes, with selection shades chosen against
the system accent and no separate icon background; import previews and overview cards retain the same palette and shapes. Native accessibility-tree labels are
inspected separately; complete VoiceOver navigation and Finder dragging still need manual checks.
Folder drop targets belong to the full-width folder labels, excluding expanded
child rows and empty placeholders; hover feedback follows the same label bounds.
The blank area below visible sidebar rows accepts root-level connection drops, including
when every connection is grouped. Its bounds follow visible rows as folders collapse or
the sidebar scrolls and resizes.
Native pointer dragging into the blank root area or empty, collapsed and nested folders
still needs manual verification; the presentation harness covers their layout only.

The sidebar implementation follows the document's primary sections 1–6. Its section 7
items remain separate future work: command palette, extended Quick Connect syntax/history
and saving, search highlighting, full drag insertion feedback and connection ordering,
additional keyboard commands, density preferences, tags, a tunnel sidebar and icon-only
sidebar mode. Existing terminal themes and VPN management remain available in Settings
and VPN Connections.

## Live validation still required

- Windows/xrdp policy differences, real resize timing, DPI application appearance,
  cursor hotspots and two/three physical displays with mixed densities, portrait,
  changed primaries, mirroring and Spaces. Exercise full-screen exit/re-entry in
  attached and detached windows, restrictions and topology changes.
- Text/file clipboard in both directions, Finder paste, idle remote Copy with
  Universal Clipboard enabled on paired devices, Windows Explorer folder
  drives, persistent selected-folder grants, audible remote sound and Unicode/IME.
- SSH algorithms/key formats, terminal programs, SFTP subsystem policies, long
  transfers, large trees, concurrent writers and unusual filesystems. Synthetic
  timing bounds do not establish production throughput or end-to-end typing latency.
- Finder dragging and sandbox-extension delivery, local Trash/cross-volume behavior,
  external-editor access, Full Disk Access setup and signed-app grant persistence.
- Production VNC servers (including supported macOS/Linux/Windows server modes),
  password policies, TLS chains, keyboard layouts, Unicode/IME, latency, resize,
  and full-screen input in attached/detached windows.
- Production WireGuard peers, IPv6-only/internal DNS, roaming, network changes,
  long sessions and performance.
- Complete keyboard/VoiceOver workflows, larger system text, short editor windows
  and long folder lists; visible Metal sharpness and native material appearance.
- Concurrent mixed sessions, suspend/resume, DNS failures and repeated
  reconnect/disconnect/quit under memory/thread diagnostics.

Use only authorized, redacted [live probes](local-testing.md). Do not infer broad
compatibility from a successful connection, channel write or synthetic renderer test.
