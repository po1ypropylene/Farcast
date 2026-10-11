# Changelog

Changes are recorded from version 1.7.0 onwards.

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
