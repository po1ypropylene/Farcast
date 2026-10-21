# Changelog

Completed changes are staged below. Version numbers and dated release entries are
assigned only when a separate release request is made.

## Unreleased

- Preserve the final SSH terminal size across backpressured resize retries, and disconnect explicitly if queued terminal input exceeds its safety limit.
- Balance forwarded Command shortcuts when macOS omits key-up, and recover RDP transports when keyboard or pointer sends fail instead of silently losing input.
- Negotiate the settled window size before connecting when RDP Resize with window is enabled, avoiding an immediate resolution change after connection.
- Keep RDP desktop frames and input responsive after closing a popped-out macOS full-screen window back to the workspace.
- Size popped-out desktop windows to the current remote resolution and Retina density, including native controls and capping them to the usable screen area.

## 2.0.1 — 2026-10-20

- Fix false RDP resolution warnings after connecting when the desktop already matches the window; retire obsolete resize deadlines while retaining warnings for genuinely unconfirmed changes.

- Add adaptive colours to session toolbar actions in main and popped-out windows, with stronger shades for Increase Contrast and grey disabled controls.

## 2.0.0 — 2026-10-20

- Fix RDP keyboard state across focus changes, missed modifier releases and graphics reactivation; reconcile left/right modifier snapshots, send physical US letters between Shift transitions, synchronize Caps Lock, clear abandoned composition and preserve native app shortcuts. Production long-session and Windows Sticky Keys behavior still require live validation.

- Refresh RDP resolution from the destination viewport after returning a popped-out session to the main window.

- Remove connection favourites, duplicate shortcut rows and star controls to free space in the connection panel.

- Move screenshot-app tooling into a separate repository; building Farcast and previewing terminal themes require only this public checkout.

- Restore SSH/RDP/VNC badges on connection rows and offer the Add menu when right-clicking empty sidebar space.
- Preview SSH terminal themes and font sizes using the screenshot app’s fictional terminal sample.

- Match Showcase SSH and SFTP mock content to the existing screenshots; configure local and server folder paths/listings independently in the demo catalog.

- Fix demo build verification after editing the sample connection count; report catalog/session errors clearly and verify the demo uses the current version and build.

## 1.6.0 — 2026-10-19

- Open Connection Details as an overlay without changing the session work area. Pin details to reserve space and resize RDP when Resize with window is enabled; remember the pin choice for main and popped-out windows.
- Move connections out of folders by dropping them anywhere in the empty sidebar space below the list.

## 1.5.1 — 2026-10-19

- Restore the VPN profile name beneath sidebar connections as user@host via VPN, including an explicit label for unavailable profiles.
- Align folder drop targets and hover feedback with the folder label instead of its expanded contents.
- Preserve teal SSH, indigo RDP and orange VNC icons with adaptive light/dark and selection shades and stronger strokes for contrast, without separate icon backgrounds.
- Automatically advance the build number by one per app build and preserve it across marketing-version changes; release and changelog rules remain unchanged.

## 1.5.0 — 2026-10-19

- Clarify the sidebar hierarchy with collapsible, persistent folders and subfolders, item counts, indented connections, quieter section headings and no empty ungrouped section. Keep host details visible, distinguish SSH/RDP/VNC icons and mark VPN routing and favorite shortcuts. Reorder favorites by dragging; view full connection metadata with Get Info.
- Add host-copy and VPN-details actions to the session status bar, VPN badges and background SSH-output indicators to session tabs, and endpoint context beneath the window title.
- Preview and import metadata from a selected SSH config without loading keys, executing directives, following includes or trusting servers.
- Add a reusable, separate screenshot app with sample connections, local terminal/file listings and original static desktops; keep all sample code and data outside the production target and DMG.
- Expand Connection Details with session and VPN status, requested and received desktop resolutions, resize progress and fallback reasons, full-screen changes and the latest connection failure.
- Fix Resize with window being ignored when a different RDP display mode was saved. Resize takes precedence for subsequent window changes; Match window at connection still determines the initial size without a resolution preset.
- Package the tested Release app without rebuilding it or advancing its build number; reject missing apps and version/build mismatches before creating a DMG.

## 1.4.0 — 2026-10-19

- Move RDP Resize with window out of the Display menu into its own always-editable checkbox alongside full-screen and Retina options, off by default for new connections.
- Keep connection status colours consistent in the sidebar, session tabs and status bar: orange while connecting or stale, green when connected, red on failure and grey when disconnected.
- Show the VPN type (WireGuard or OpenVPN), profile and transport status in the bottom bar for sessions using a VPN, including startup, readiness, failure and disconnection.

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
