# Changelog

Changes are recorded from version 1.7.0 onwards.

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
