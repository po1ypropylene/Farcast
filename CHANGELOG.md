# Changelog

Completed changes are staged below. Version numbers and dated release entries are
assigned only when a separate release request is made.

## Unreleased

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

## 2.4.0 — 2026-11-08

- Fix single-monitor RDP “Resize with window” to request full-screen dimensions from the top-right action and restore window dimensions on exit, including rapid transitions and Retina scaling.

- Fix experimental RDP frame buffers accumulating until disconnect by releasing temporary snapshot and Swift bridging storage after every paint callback.

- Add optional connection-folder storage (default `~/.farcast-connections`) with AES-128 key-file or password protection and an unencrypted option. Retain original app-library/Keychain storage; offer in-app migration when switching, preserving source data.

- Improve readability of VNC authentication, media negotiation and recovery, RDP drive registration and color conversion, and VPN ZIP validation with descriptive names and clearer authentication stages; preserve existing protocol behavior.

## 2.3.0 — 2026-11-01

- Count files recursively across all selected SFTP transfer folders using reusable preflight scans, and open the local folder picker from the path instead of the Local Mac heading.

- Disconnect RDP sessions for Mac sleep, stop their connected timers and hide outdated desktops. Add an off-by-default Settings option to reconnect after wake, waiting for old transport cleanup.

- Fix duplicate cursors in Apple VNC by using the server-drawn pointer in the desktop image, including full screen and TCP fallback; keep the local pointer over window controls and letterboxing.

- Synchronize desktop presentation with the destination display and recreate its display link after window transfers.
- Reduce Adaptive Mac VNC packet/NAL and compressed-frame copies; skip queued work only at complete random-access pictures and retry recovery with bounded backoff.
- Batch queued Apple VNC input records, reduce record allocations, preserve native layout shortcut symbols and add Pause, extended function and Japanese language keys with balanced releases.
- Clarify Apple negotiation layouts, bandwidth mode flags and typed authentication errors. Real-Mac interoperability and performance comparisons remain user validation.

## 2.2.0 — 2026-10-25

- Add native YCbCr rendering, populated RTCP reception reports, bounded packet retransmission requests and negotiated long-term-reference acknowledgements to Adaptive Mac VNC. Production loss recovery and sustained 4K latency still need live validation.
- Bound Adaptive HEVC decode work, remove per-frame synchronous waits and CPU pixel copies, and import retained video surfaces directly into Metal. Wake the media worker on UDP arrival and retry reference-picture recovery after later packet loss.
- Coalesce adjacent VNC pointer motion without dropping button/key transitions, reuse the Apple input cipher across events and rekeys, and cache keysym tables with additional navigation/system keys.

- Preserve committed character keysyms when VNC enters full screen.
- Preserve uppercase letters and shifted punctuation in VNC by sending AppKit’s committed character keysyms; RDP retains physical scan-code input.

- Fix Mac VNC keyboard and pointer input with Apple's encrypted event format and session-key rotation. Preserve framebuffer-pixel coordinates for Retina, keep framebuffer refreshes running, and service queued input during receive waits.
- Support server-requested encrypted Mac desktop-login handoff using the saved account credentials; macOS session state and policy can still require manual login.

- Add “Remote desktop is a Mac” for VNC, with an opt-in encrypted Apple virtual display, resolution/Retina settings and window-driven resize requests. Direct connections try Adaptive HEVC with hardware decoding, fresh video after confirmed resize and full-quality TCP fallback. VPN sessions retain TCP; audio and HDR are not included. Some Mac hosts still show both local and remote cursors.
- Restore Apple framebuffer updates after virtual-display size changes, and wait for desktop pixels before reporting Connected.
- Report VNC TCP and authentication-stage failures instead of hiding the underlying connection error.

- Recover stalled RDP clipboard format requests, preserve local text when the remote copies unsupported formats, and retain temporary-storage accounting while completed file batches remain available.
- Harden RDP setup/cleanup and clipboard file ownership; keep Ctrl–Alt–Delete ordered as one queued sequence and report rejected graphics setup in redacted diagnostics.

- Clarify the shared VPN helper structure, separating WireGuard setup from shared session handling; retain existing saved profiles and helper compatibility.

## 2.1.0 — 2026-10-22

- Add an off-by-default Settings switch for experimental RDP graphics, input wakeups and dirty-region updates; changes apply on the next connection. Hide experimental Connection Details when disabled and clarify GPU texture write metrics.
- Remove superseded review reports and question-and-answer records; retain current architecture, procedures and validation limits.
- Simplify Settings About to show the version and build number; remove the Protocols row and Security section.

- Support optional GFX/H.264 with source-built OpenH264 and initialize its decoder on the protocol graphics channel; retry once with compatible graphics if initial frames fail to arrive.
- Wake the RDP worker immediately for queued input and upload only missed desktop damage when experimental mode is enabled.
- Show observed graphics codecs, local pipeline activity and visible presentation metrics for experimental sessions; activity ages do not establish remote-path health.

## 2.0.2 — 2026-10-22

- Pace RDP/VNC desktop uploads to the display refresh rate, coalesce updates during GPU work and preserve Metal drawable resources between frames to reduce presentation overhead.

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
