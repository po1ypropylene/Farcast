# Changelog

Completed changes are staged below. Version numbers and dated release entries are
assigned only when a separate release request is made.

## Unreleased

- Keep connection status colours consistent in the sidebar, session tabs and status bar: orange while connecting or stale, green when connected, red on failure and grey when disconnected.
- Show the VPN profile and transport status in the bottom bar for sessions using a VPN, including startup, readiness, failure and disconnection.

## 1.3.0 — 2026-10-18

- Make VPN profile fields visibly editable, group essential and advanced settings, add secure-field controls and import status/drop zones, and protect unsaved edits with Save, Revert and discard confirmation. Show field validation and keep the selected profile name in sync.
- Group Settings into General, Terminal, Security and About with contextual help and content-sized layout; separate VPN management from library imports in the File menu.
- Add OpenVPN alongside WireGuard in VPN Connections, with profile import, protected credential storage and shared app-private tunnels for SSH/SFTP, RDP and VNC. Scripts, unresolved files, TAP, proxies, unsupported compression and interactive MFA are refused; production OpenVPN compatibility remains unverified.
- Import OpenVPN ZIP bundles and extracted folders, or select referenced certificates and keys individually in a review sheet. Explain incompatible TAP exports and guide Orbi users to the For Smart Phone TUN export. Support legacy AES-CBC and explicitly enabled incoming LZO compression while keeping outgoing data uncompressed.

## 1.2.0 — 2026-10-17

- Replace libssh2 1.11.1 with a pinned master snapshot containing the CVE-2026-55200 packet-length bounds fix and subsequent upstream fixes. Dependency refreshes keep following master through immutable commit pins.
- Detect lost RDP transports and stalled protocol workers, show the connection state promptly, and retry established sessions up to three times in the same tab. Cancel stops recovery; authentication, trust and server-policy failures require manual action.

## 1.1.0 — 2026-10-16

- Fix SSH terminal context-menu action validation and allow explicit Paste anywhere in a connected terminal, matching ⌘V. Keep automatic right-click paste limited to the live cursor line and Cut unavailable.
- Center the Tunnels page in a shared 720-point column with a persistent header, a full-width empty card and Local forward, SOCKS5 proxy and Remote forward quick starts. Show Edit saved tunnels only when saved rules exist; keep stopped rules visible and startable.
- Use native toolbar controls grouped by session and view actions, clarify the pop-out window icon, and add Session → Disconnect All with conditional interruption confirmation.
- Distinguish rounded session tabs from secondary view tabs, show the active connection in the window title, and improve sidebar section labels and username context without changing sidebar selection behavior.
- Restrict terminal zoom and Find controls to Terminal/Split View, make the zoom percentage resettable, and use compact live connection uptime in the status bar and sidebar.
- Reset the app baseline to 1.0.0 build 1, clear prior changelog history and stage future changes until an explicit release request. Local builds remain development-signed and unnotarized.
