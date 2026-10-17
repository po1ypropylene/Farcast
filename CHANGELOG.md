# Changelog

Completed changes are staged below. Version numbers and dated release entries are
assigned only when a separate release request is made.

## Unreleased

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
