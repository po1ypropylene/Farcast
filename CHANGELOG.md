# Changelog

Completed changes are staged below. Version numbers and dated release entries are
assigned only when a separate release request is made.

## Unreleased

## 2.11.0 — 2026-11-27

- SSH file copies now prefer rsync on new and existing profiles. Farcast includes rsync 3.5.2, uses the authenticated SSH session, and can fall back to SFTP. Set the method and compression per connection in Files. Compression starts off.
- Set overwrite behavior in Files and edit terminal appearance and transfer settings without reconnecting.

- Capture the visible SSH terminal or RDP/VNC desktop with the camera button or ⇧⌘S. Screenshots retain native pixel dimensions and can be saved as PNG or JPEG, copied to the clipboard, or both. Choose destinations and feedback in Settings → Screenshots.

## 2.10.0 — 2026-11-22

- Type or paste in either SFTP path field to filter recent folders in an overlay below it. Return opens the typed path, or the suggestion highlighted with the arrow keys. Local history is shared across connections and server history is saved per connection.

- Prevent a double-click from confirming two SFTP overwrite prompts. Dragging off Stop Transfer before releasing now leaves the transfer pending.

## 2.9.1 — 2026-11-19

- Fix SFTP overwrite alerts after drag-and-drop so they open automatically and all three actions respond on the first click. Show when either file pane finishes refreshing.
- Use **Save & Reconnect** when editing a connection with an open tab, even if it is disconnected. Reconnect in place with the saved settings and switch to that tab.

## 2.9.0 — 2026-11-15

- Align About actions in labeled columns, add stable-width copy feedback and allow a small Settings height margin to avoid unnecessary scrolling.

- Put one Connections heading above the sidebar tree, with flat folder-aware search results and a root drop target on the heading.
- Prioritize the selected connection in the workspace, clarify new-connection actions and show storage-aware credential privacy text with a Storage settings link. Display endpoint ports without number-grouping separators.
- Size Settings to the selected pane and screen, retain the last tab, align controls and show pending storage actions only when needed, with a close-time review choice.
- Compact Storage settings, explain encryption in an info popover and remember successful key backups per key. Add copyable system information, bundled acknowledgements and release notes in About.

- Import a Farcast connections folder and matching key from any selected location, with hidden-file-aware pickers, credential unlock and review.
- Choose non-destructive merge or confirmed clearing of existing connections, folders, VPN profiles and their associated credentials; retain source files and protect imported credentials using current storage settings.

## 2.8.0 — 2026-11-13

- Keep Apple numeric keypad digits and operators numeric in SSH, RDP and VNC; synchronize RDP Num Lock on and preserve VNC Clear without toggling Num Lock.

- Make WireGuard routing automatic for new profiles, with optional Allowed IPs under Advanced. Preserve saved/imported ranges and split DNS; automatic routing sends configured DNS through the app-private VPN.

## 2.7.0 — 2026-11-11

- Keep the live desktop attached after repeated pop-out window returns, and open Connection Details in the window owning the session.
- Reject embedded null characters in connection fields and numeric tunnel addresses; validate percent-encoded Quick Connect hosts.
- Bound SSH config import candidates and replace regex wildcard matching to prevent excessive backtracking.
- Refuse special local upload sources without blocking SSH, detect changed local copy/upload sources and retain source data on failure.
- Preserve absent optional Mac VNC metadata when importing an existing library.
- Restore VPN lifecycle and display migration regression harnesses after storage and import dependencies were added.
- Document installation and first-launch approval for the unnotarized app in macOS Privacy & Security.
- Require warning-free Xcode app builds before delivery or packaging.

- Remove Xcode build warnings while preserving Apple VNC authentication and safe RDP frame bounds.

- Add “Connect Direct” below “Connect” in VPN-routed connections’ context menus, bypassing the saved VPN for that session and its reconnects.

## 2.6.0 — 2026-11-10

- Choose in Settings whether opening an already connected profile creates another session or switches to its connected tab or popped-out window.

- Accept SFTP drops across the whole local or server file area, including empty folders, without insertion-position feedback.
- Show completed-file progress across multi-file SFTP transfers, including recursive folders; retain byte progress for a single file.

## 2.5.0 — 2026-11-08

- Show “Deleting” instead of “Preparing” in remote file deletion progress.

- Bound temporary SSH/SFTP memory during long transfers and recursive operations; avoid redundant parent-directory listings and reject invalid paths or uncertain rename checks.
- Prevent RDP file selections and redirected-folder handles from exhausting descriptors; grow filename replies safely, synchronize clipboard cleanup and release failed cursor/video setup resources.

- Clarify connection storage with a dedicated Settings pane, active versus pending status, Revert, migration preflight and existing-library choices, visible protection warnings, and labeled key selection, generation and backup actions.
