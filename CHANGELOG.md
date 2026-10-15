# Changelog

Changes are recorded from version 1.7.0 onwards.

## 2.3.2 — 15 October 2026

- Cancel pending RDP clipboard transfers when clipboard ownership ends, including replacement during a stalled paste. Share one provider across each batch, preserve per-item reentrancy protection, and keep completed files available.
- Cancel queued redirected-folder operations before draining the device worker at shutdown, preventing queued writes, creates and delete-on-close from running during teardown. An already executing filesystem operation may finish.
- Coalesce consecutive RDP pointer moves and disconnect with an explicit error if the bounded input queue overloads, instead of silently dropping key releases, buttons or clipboard deactivation.
- Match square brackets literally in redirected-folder searches while retaining case-insensitive `*` and `?` matching.
- Cover clipboard replacement without a remote response, multi-item fulfillment, unconsumed ownership loss and queued filesystem cancellation with isolated regression tests. Production copy/paste and directory throughput still require live verification.

## 2.3.1 — 15 October 2026

- License Farcast's original source under MIT, permitting free use, modification and redistribution with the license notice retained. Include LICENSE in the app and DMG; bundled dependencies keep their own licenses.
- Advertise Windows clipboard files without downloading their contents on Copy. Begin size/range requests only when a Mac pasteboard consumer requests the files, and prevent focus changes or another session from consuming Farcast's own delayed clipboard items.
- Keep native event handling active during synchronous paste fulfillment; publish only complete files and preserve a newer local copy.
- Stream redirected-folder enumeration instead of scanning/sorting the entire directory first. Avoid duplicate metadata reads and large per-entry response allocations, remove the 20,000-entry listing cap, and keep independent search cursors with list-access checks. Clean up directory descriptors on enumeration setup failure. Reject inbound files above 4 GiB when large-file support was not negotiated.
- Synthetic coverage includes lazy 50 MB file transfers and directories above 20,000 entries. Real Finder/Windows copy-paste and comparative directory throughput still require live verification.

## 2.3.0 — 15 October 2026

- Add, edit, duplicate, start, stop and remove SSH tunnels in a live session without reconnecting. Save to the connection or keep a tunnel for this session only. Show actual listener addresses with copy controls, status and actionable failures.
- Align saved/live tunnel forms, show Auto for empty listen ports, add plain-language paths and contextual security hints, and constrain live cards and empty states to one content container.
- Defer new-connection hostname errors until the address is skipped or Save is attempted. Defer new tunnel errors until edited fields lose focus or Save is attempted; show inline errors once with an issue-count footer.
- Unify underline navigation, group toolbar commands, add sidebar session state/uptime and terminal zoom/reset, and confirm session interruption when file work or tunnels are active. Remove redundant sidebar labels and tagline.
- Accept user@host:port and SSH/RDP/VNC URLs in Quick Connect. Preserve every connection setting on duplication, including WireGuard and raw optional metadata; copies require their own credentials.
- Live tunnel behavior is covered by owned SSH peers. Production server policy, full VoiceOver workflows and measured light/dark contrast still require live verification.

## 2.2.0 — 14 October 2026

- Add saved local TCP, SOCKS5 CONNECT and remote TCP tunnel rules, with automatic or fixed listener ports, Start on connect, and live Start/Stop controls, state, bound ports and connection counts.
- Share the authenticated SSH session and optional WireGuard transport with terminal/SFTP. Keep forwarding active during file work and overwrite prompts; support accounts that allow forwarding but deny shell and SFTP. Preserve existing profiles with optional tunnel metadata.
- Bound connections and queues, handle partial writes and each EOF direction independently, and close listeners on stop, disconnect, reconnect and quit. Avoid keepalive reply conflicts with remote-listener requests.
- Local listeners are loopback-only and SOCKS5 has no proxy authentication. BIND, UDP, HTTP CONNECT and automatic system-proxy changes are unsupported. Remote listener access depends on server policy; SSH-server-to-destination encryption is the destination application's responsibility. Production forwarding policy and long-running performance remain unverified.

## 2.1.0 — 14 October 2026

- Add Back/Forward navigation to server file browsing and independent local/server filename filters. Selection, Select All, transfers and context actions operate on visible items.
- Reuse recent server folder listings for up to 30 seconds to avoid repeated network reads. Bound the session-only cache, bypass it on Refresh, and invalidate it before remote changes and on reconnect/disconnect. Cached listings are identified in the status bar; other clients' changes require Refresh or cache expiry.
- Preserve the shared SSH login, terminal-aware transfer pipeline and native preflight/overwrite checks. Synthetic browsing and transfer coverage does not establish production-server speed or full accessibility coverage.

## 2.0.3 — 13 October 2026

- Build 2: include the compatibility padding byte in empty RDP directory replies, including enumeration end. This fixes incomplete Explorer listings and subsequent invalid-address errors. Retain version 2.0.3 as requested.
- Accept directory paths ending in a separator, retain directory intent and use a canonical path for directory handles, sharing checks and later requests. Regular files cannot be opened as directories; traversal, repeated separators and symlinks remain rejected.
- Extend redirected-folder checks below the root through two subfolder levels, including Unicode names, file reads/writes, metadata, create/rename/delete and read-only denial. Direct RDP and encrypted WireGuard fixtures exercise nested browsing and file access. Build 2 verifies complete visible listings and repeated nested browsing on an authorized real Windows machine with direct transport; real writes remain unverified.

## 2.0.2 — 13 October 2026

- Remove a forbidden padding byte from RDP folder directory-listing replies. Preserve the exact filename offsets required by Windows Explorer's directory information format.
- Correct empty-search/end-of-directory status codes and ignore unused path fields during continuation requests.
- Cover root browsing, Unicode names, file reads/writes and read-only denial through direct and encrypted WireGuard synthetic sessions. Real Windows acceptance of the reported folder-access error still requires a retry.

## 2.0.1 — 13 October 2026

- Correct redirected-folder drive-name encoding to match Windows App and FreeRDP, and decode UTF-8 names/paths explicitly during device registration. Preserve the selected-folder access policy. Reconnect to announce the corrected drives.
- Publish Windows clipboard file items to Finder while their contents are being received. Fulfill only complete local files; wake waiting paste operations on cancellation or disconnect.
- Pipeline up to eight bounded file-range requests, support reordered and short replies, and show received-byte progress for large clipboard files. Serve larger peer requests with bounded short responses.
- Real Windows/Finder transfers and redirected-drive acceptance still require live validation; synthetic 50 MB byte-equality checks do not establish production throughput.

## 2.0.0 — 13 October 2026

- Add saved and Quick Connect VNC desktops with password/no-password and certificate-based VeNCrypt TLS authentication, native Metal presentation, fit/scrolling and single-display full screen.
- Share the existing WireGuard tunnel across SSH, RDP and VNC with independent leases, no direct fallback, reconnect and coordinated shutdown. Preserve existing profile metadata and credentials.
- Add Paste Text from Clipboard and Command–V for explicit, cancellable Unicode keyboard typing into VNC. Add Ctrl+Alt+Delete controls; no automatic VNC clipboard or file sharing occurs.
- Classic VNC is unencrypted; use WireGuard on untrusted networks. ARD/proprietary authentication, anonymous TLS, file/audio/cursor channels, remote resolution requests and multiple local VNC displays are unsupported. Production-server and keyboard-layout interoperability remains unverified.
- Advance to 2.0.0 as requested for the VNC delivery; existing data and SSH/RDP workflows remain compatible.

## 1.10.0 — 12 October 2026

- Add WireGuard to SSH connections, including terminal and SFTP access over the same authenticated SSH session.
- Share one tunnel across SSH and RDP tabs using the same saved WireGuard profile. Disconnecting one tab retains the other sessions; failed tunnels never fall back to direct connections.
- Preserve the original SSH host-key and RDP certificate identity, and show WireGuard selections for both protocols in the editor and sidebar.
- Separate SSH terminal, SFTP transfer and tree workers into private implementation files; separate RDP folder-provider registration from its filesystem backend. Keep existing worker ownership and behavior.
- Reuse protocol-independent tunnel startup and socket authentication. Production-peer interoperability and network-change recovery still require live validation.

## 1.9.2 — 12 October 2026

- Keep Exit Full Screen readable over bright and dark remote desktops with an opaque native background that follows the Mac appearance.
- Disable windowed display modes and resolution controls when Open in full screen is selected; retain those settings for windowed connections.

## 1.9.1 — 12 October 2026

- Make Resize with window reach the server's Display Control channel and update the existing desktop without reconnecting. Coalesce live/programmatic resizing, use viewport points or Retina backing pixels once, and keep input/rendering tied to received geometry.
- Retain the newest request while capabilities arrive, enforce server limits, and report a usable local-fit fallback for unsupported, rejected or unconfirmed changes. Multi-monitor layouts remain fixed until reconnecting.
- Fix single-monitor full-screen activation timeouts caused by waiting for an unnecessary Monitor Layout reply. Preserve full display resolution and Retina scaling; full-screen exit/re-entry remains available.

## 1.9.0 — 11 October 2026

- Give General, Display, Devices & audio, Terminal and Security their own full-size editor tabs, replacing the cramped advanced disclosure area.
- Keep the header, tab bar and actions fixed; align fields with a shared wider label column and keep resolution units within the row.
- Choose common RDP resolutions from a preset list, or use Custom for free-form pixel dimensions. Existing custom sizes and display modes are preserved.
- Add opt-in RDP startup full screen, all-monitor negotiation and Retina resolution/UI scaling, with one authenticated session and a cropped native surface per display. Retina identifies selected sizes as Mac points.
- Share one latest framebuffer across displays; keep rendering, pointer coordinates and cursor scaling aligned. Missing or changed server layouts stay usable in the workspace.
- Build 2: the top-right RDP full-screen action returns to the connected remote desktop after exiting, including its negotiated monitors, without reconnecting. It is also available in detached session windows and after windowed startup.
- Preserve legacy display defaults and profile metadata. Display-topology changes require reconnecting; real Windows multi-display, mixed-DPI and Spaces behavior remains unverified.
- Mark tabs with existing validation errors and let the footer hint navigate to them. Preserve all options, protocol editing, credential policy and save/connect behavior.

## 1.8.2 — 11 October 2026

- Make the connection editor compact, with nearby labels, bordered inputs, adjacent sign-in fields and collapsed advanced sections.
- Separate RDP network, display, devices/audio and security controls; retain all existing display modes, initial resolutions, folder actions and terminal settings.
- Add password visibility controls, inline validation and an explicit edit title. Keep existing credential storage, protocol switching, validation and save/connect behavior.

## 1.8.1 — 11 October 2026

- Adopt the supplied v5 monitor-and-broadcast logo in the app icon, sidebar mark and README icon.
- Preserve editable native Icon Composer layers and existing screenshots.

## 1.8.0 — 11 October 2026

- Add a Settings choice for SSH right-click: a native context menu (default), or automatic copy/paste. Changes apply to open terminals immediately.
- Copy selected text or a clicked output line, paste text on the active cursor line, and search text with Google from the menu. File clipboard contents are ignored; disconnected terminals cannot paste.
- Preserve remote mouse reporting; Shift–right-click opens local actions. Cut is disabled because terminal selections cannot safely delete remote input. Cursor-line targeting is approximate for remote/full-screen programs.

## 1.7.4 — 11 October 2026

- Keep the terminal background inside its workspace so it no longer tints the connection sidebar through transparency.

## 1.7.3 — 11 October 2026

- Sign local app updates with a consistent Apple Development identity so Keychain approval can survive rebuilds.
- Pin the selected certificate and verified signing requirement locally; refuse silent fallback to ad-hoc signing or a changed app identity.
- Verify signing continuity and the packaged changelog in the mounted DMG.
- Existing ad-hoc Keychain grants may need one final Always Allow approval per saved credential when adopting the certificate-signed app. Credential contents and access controls are preserved.

## 1.7.2 — 11 October 2026

- Keep terminal input responsive during SFTP uploads and downloads in Terminal/Split mode by bounding file data queued on the shared SSH transport.
- Retain the larger upload/download pipeline in Files mode; changing modes adjusts the budget during a transfer after previously queued packets drain.
- Service terminal I/O more frequently during transfer waits and preserve terminal write arguments across nonblocking retries.
- Add sustained, bandwidth-limited terminal latency and Files-to-Split regression checks with byte-verified round trips.

## 1.7.1 — 11 October 2026

- Restore compact native Mac button, form, list and font sizes; reduce session tabs to Safari-like proportions.
- Update UI guidance to keep touch/iPad sizing separate from the Mac app.
- Size SFTP transfer buffers to each file to avoid oversized allocations for small files.
- Increase the large-download window to 1 MiB and reduce upload-buffer copying while keeping pipelined retries intact.
- Create new upload destinations exclusively before checking for conflicts, removing a redundant request for new files.
- Reuse complete directory-listing metadata during recursive download preflight, with a fallback for incomplete listings.
- Preserve one shared SSH session, transfer-time source checks, overwrite approval and atomic replacement.
- Drain queued download replies within a bounded close deadline so cancellation preserves file-only sessions and services terminal input.

## 1.7.0 — 11 October 2026

- Remove the duplicate saved-connection list from Home and centre the remaining content.
- Keep RDP file-clipboard status in the existing bottom status bar without shifting the desktop.
- Show SFTP transfer speed for the current file, including recursive uploads and downloads.
- Add first-use file-access setup with Full Disk Access settings and the existing local-folder grant.
- Add hover tooltips to connection toolbar buttons.
- Pop an existing SSH/SFTP or RDP connection into its own resizable window; return it without reconnecting.
- Require a verified versioned DMG and changelog for future app deliveries; include this changelog in the DMG.

Local DMGs remain ad-hoc signed and unnotarized. Full Disk Access must be enabled
manually; local-folder access remains subject to macOS sandbox permissions.
