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
| VNC | RFB versions/security, DES challenge, TLS trust/refusal, raw/CopyRect/Hextile/Zlib/resize, Unicode input, cancellation; Apple RSA-SRP, encrypted records, desktop-login handoff/refusal, virtual-display resize/control renewal, encrypted key/click releases, Retina coordinates, request-driven interactive redraws, connected-after-pixels, key/group/proof/integrity rejection and optional-setting migration | Owned synthetic peers; one authorized Mac confirms RSA-SRP, visible TCP framebuffer, window resize and Retina backing dimensions. The user also verified ongoing visual updates, aligned pointer clicks and responsive keyboard input on that Mac. The Adaptive receiver has synthetic authenticated-UDP/hardware HEVC coverage and has hardware-decoded and visibly presented one authorized Mac’s desktop over live SRTP. The user confirmed aligned clicks, working keyboard input and responsiveness almost comparable to Apple Screen Sharing. Other host versions, long sessions and input layouts remain unverified |
| RDP channels | TLS/NLA, frames, clipboard text/files, retained-batch quota, cancelled-generation format timeout, detach callbacks, reserved names and preservation of local text for unsupported formats; folder drives, Display Control PDUs, initial monitor attributes and pointer input | Synthetic peers; channel submission does not prove Windows acceptance |
| RDP keyboard | Left/right and duplicate modifier snapshots, overlapping Shifts, physical shifted letters, missed-release repair, focus/activation cleanup, Caps Lock synchronization, native window key repeat, menu routing and Unicode pairs; suspended-input retention with clipboard-control progress; TLS/NLA peer decodes ordered keyboard PDUs before and after resumption | Owned AppKit windows and loopback peers; production intermittent failure and Windows Sticky Keys behavior remain unverified. See [keyboard input contract](rdp-keyboard.md) |
| RDP recovery | Idle worker health, stalled-worker interruption, abrupt peer loss, visible stale/failed/reconnecting state, three-attempt backoff, cancellation, teardown ordering, callback generations and same-tab TLS reauthentication | Owned TLS peer and controlled native callbacks; production long-session failure reproduction remains pending |
| RDP folder browsing | Packed directory formats, compatibility padding at enumeration end, Unicode pagination, trailing separators and nested files; direct/WireGuard fixtures | Signed app on one authorized Windows server with direct transport: complete visible root count and repeated browsing through two subfolder levels. Real writes and other server policies remain unverified |
| RDP presentation | Cropped Metal uploads, inverse input mapping, letterbox/stale-frame rejection, full-screen startup/exit/re-entry and teardown; closing actual macOS full-screen windows repeatedly preserves first/subsequent frame uploads, latest-frame bursts and keyboard/mouse input without forced test redraws; production pop-out desktop bounds match remote resolution when it fits; matching initial geometry stays free of fallback notices past the deadline during mouse movement and delayed capabilities; genuine missing/ignored/restricted resize fallback; resize opt-in overrides all stored display modes and repeated pop-out/resize/close returns converge on server geometry with Retina on/off against an owned Display Control peer | Marked frames and owned off-screen windows |
| Workspace | Overlay/pinned connection-details viewport geometry and surface identity in attached/detached windows, persisted pin preference; tab ordering/reconnect, detached surface ownership, focus/prompt routing, terminal menus, deferred connection/tunnel validation, centered empty/stopped tunnel layouts at narrow/wide sizes in light/dark, template type selection, view-specific terminal tools, adaptive session-action colours and disabled controls in light/dark, detached Increase Contrast previews, conditional Disconnect All and AppKit shutdown | Synthetic sessions, private pasteboards and preferences |
| Connection status | Inspector failure retention, VPN lifecycle activity, initial/submitted/observed RDP geometry and resize fallback events; shared sidebar/tab/status-bar colours across all session states in light/dark; per-session VPN startup, readiness, failure, release and recovery while other sessions share the helper | Owned native windows and encrypted loopback peers; VPN Ready indicates an available destination lease, not continuous peer-health verification |
| VPN editor and Settings | Field validation and engine bounds, initial selection, dirty/Cancel/Revert/Save, secure-field controls, import summaries and grouped Settings in light/dark | Synthetic credentials and owned native windows; full VoiceOver and Finder drops need manual verification |
| OpenVPN | Safe profile import, credential coding, ZIP/folder/manual companion import, UDP/TCP TLS negotiation, legacy AES-CBC/LZO framing, encrypted outbound IP delivery, certificate rejection, shared leases, route refusal and cancellation against an owned null-device peer | Synthetic certificates only; production interoperability and full desktop/file traffic remain unverified |
| WireGuard | Encrypted loopback traffic, concurrent SSH/SFTP/RDP/VNC on one helper, independent disconnect/reconnect, DNS/route and host-key refusal, shared-helper failure/cleanup and schema migration | Generated keys and owned peers |
| Packaging/signing | Platform, library closure, signatures, loader, sandboxed helper, certificate continuity, mounted bundle and SHA256 | Local development artifact; distribution is separate |
| Maintenance | Cleanup boundaries, dependency rollback, signing policy, harness teardown, VPN helper source migration and repository hygiene | Disposable files and mocked destructive operations |

## Known implementation limits

The 4K desktop presentation load fixture checks final-frame convergence and reports
CPU time/run-loop gaps under excess frame publication. Refresh pacing and GPU
ownership are local renderer changes shared by RDP and VNC; they do not establish
production frame rate or end-to-end input latency.

Deterministic regressions cover SSH submitted-versus-desired PTY resize through
EAGAIN, partial-write ordering, explicit input overflow, omitted Command key-up,
and failure of each RDP input send API. These do not reproduce a production
long-session incident or establish physical network/sleep behavior.

RDP startup resize coverage uses owned native windows and a Display Control peer:
stored Fit, Actual Size and Match window modes with resizing enabled negotiate the
viewport initially, apply Retina once and send no redundant startup layout. Checks
also cover layout settling, even-width normalization and cancellation before connection.
Production Windows startup smoothness still requires live validation.

- **Keychain:** synchronous operations can block UI callers during authorization
  or unlocking. The local-file fallback cannot help while a call is waiting.
  Moving I/O off the main actor needs an explicit prompt/cancellation policy.
- **RDP display:** the optional experimental RDP mode requests GFX/H.264 through source-built
  OpenH264, with a one-shot initial-frame fallback to compatible bitmaps. Actual
  CPU tradeoffs and Windows policy interoperability still require the user's
  comparison. Synthetic codec tests prove AVC420/AVC444 decoding support, not
  Windows server codec selection or production startup reliability. Dirty patches
  preserve a coherent canonical image and bounded per-surface damage history;
  synthetic pixel equality does not prove production visual correctness. Native
  full-screen entry and return still require manual confirmation on the final
  build. Local activity ages are diagnostic signals,
  not a complete remote-path liveness detector. Dynamic
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
  batches are temporary and copy-only. Live staging, retained completed batches and
  their cleanup grace periods share an 8 GiB / 20,000-entry process budget.
  Legacy immediate consumers retain their reservations until disconnect. Cleanup
  after a crash remains the OS temporary-directory policy; the budget is not a
  disk-free-space guarantee.
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
- **Apple Adaptive video:** synthetic hardware encode/decode checks cover native
  NV12 IOSurface output, exact NACK repair, populated receiver reports and repeated
  authenticated FIR backoff after post-frame loss and newest-complete-IRAP burst
  selection before decode. Reusable compressed storage is exercised through later
  asynchronous output and close. LTR checks cover explicit marked
  references, DON/timestamp identifiers and acknowledgement preservation after failed
  decode. Owned GPU checks exercise BT.601/709/2020 SDR conversion in full/video range,
  surface retention, suspension/resume, the full-frame crop used in full screen and
  same-size TCP fallback. Full-screen surfaces retain the VNC committed-character
  input policy. Semantic special-key repeat/focus cleanup and layout-aware shortcuts
  have synthetic coverage. Owned window-transfer and texture-resume checks cover
  renderer lifetime; locked/occluded windows cannot establish visible display-link
  callbacks or vsync behavior. Production sender
  adaptation, proprietary LTR reference selection, physical Wi-Fi loss recovery and
  sustained 4K throughput still require live validation; synthetic/static evidence
  does not establish latency parity with Apple's client.
- **VNC:** classic password/no-auth has no desktop encryption or server identity;
  use WireGuard on untrusted networks. VeNCrypt requires supported X509 modes.
  Apple virtual-display mode supports RSA-SRP, full-quality TCP and experimental direct Adaptive HEVC.
  Live resize refreshes without pointer movement. The tested host still displays
  both local and remote cursors despite the media cursor-omission request.
  Media startup can receive no UDP datagrams and fall back to TCP; reconnect retries Adaptive.
  HDR, legacy Apple DH/Kerberos/direct-SRP, anonymous TLS and
  file/audio/cursor channels are unsupported. Standard VNC cannot request resolution changes. Clipboard typing depends on server Unicode
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

Experimental RDP features are controlled by the off-by-default switch in Settings.
Each RDP connection snapshots it: disabled uses compatible bitmap graphics, full
frame snapshots/uploads and polling input; enabled uses GFX/H.264 negotiation with
startup fallback, immediate input wakeups and dirty-region snapshots/uploads.
Changes take effect on the next connection or reconnect; disabling immediately
hides experimental Connection Details. Baseline refresh pacing and drawable
lifecycle fixes remain active in both modes. OpenH264 remains bundled as an
optional software decoder; the server selects the actual codec.
