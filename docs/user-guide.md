# Using Farcast

## Move an existing library to Farcast

Farcast has a new app identity and starts with its own library. The previous
library and credentials stay in place; do not run a data-reset script to migrate.

1. Quit the previous app. In Farcast, close all session tabs and use an empty
   library. Import refuses to overwrite existing profiles, folders or tunnels.
2. Choose **File → Import Existing Library…** (also available from **Add**).
3. Enable **Copy saved local credentials** only if you want to copy passwords,
   imported keys and WireGuard keys stored in local files. These copies remain
   unencrypted, owner-only files. Keychain credentials are not copied.
4. Choose **Choose Library Folder…**. In the macOS folder picker, press
   **Command–Shift–G** and enter the previous container location:
   `~/Library/Containers/com.peterpo.UniversalRemote/Data/Library`.
   Select that **Library** directory, not Application Support or the repository.
5. Saved profiles/folders/tunnels and their IDs, notes, dates, settings and prior
   trust decisions are imported. Restored tabs stay disconnected. Enter any
   Keychain credentials again and reselect local/shared folders when macOS asks.

The importer opens a disposable copy of the database and leaves original files
unchanged. It does not export Keychain, connect to servers or copy unrelated
preferences. A rejected import preserves the original library; errors omit paths,
server information and credential values.

## Open the app

The local release build is at:

```text
.build/Xcode/Build/Products/Release/Farcast.app
```

Open it directly, or copy the app to Applications. Its protocol libraries are
bundled: users do not need Homebrew, an SSH agent, FreeRDP, or OpenSSL installed.
This local development build is Apple Development signed with hardened runtime disabled,
not Developer ID signed or notarized. Enable hardened runtime explicitly when
using a real distribution identity.
A public release still needs signing, notarization, and validation on real servers.
The deployment target is macOS 27 and architecture is arm64. Intel and older macOS
releases are unsupported.

### Keychain approval after updates

Version 1.7.3 onwards uses a consistent certificate-backed identity for local updates.
After installing this first certificate-signed build, macOS may ask once more for
existing saved credentials. Enter your **Mac login/Keychain password** in the macOS
dialog and choose **Always Allow** once per saved credential to retain the approval. Future builds with the
same signing identity should reuse it. This is separate from your server password.
The app preserves existing credentials and their protection. A signing-team/channel
change, renewed certificate with a changed identity, or a locked Keychain can still
require approval; report recurring prompts rather than deleting your saved credentials.

## Connect

1. Choose **SSH Terminal**, **Remote Desktop**, or **Quick Connect**.
2. Enter the protocol, name, server address, port, username and password in the
   connection editor. Server address is just the IP address or host name. Port is
   a separate field, initially 22 for SSH or 3389 for RDP. RDP also has an optional domain. Use the pinned **Display**, **Devices & audio**,
   **Terminal** and **Security** tabs for the applicable options. The form opens on
   **General**; tab changes keep the values you entered.
3. For SSH, choose Password or select an imported private key. Password also supports
   servers that request it through keyboard-interactive; additional codes/questions
   appear separately. Explicit Keyboard-interactive displays every server prompt.
   Keys and their passphrases can be saved on this Mac. There is no SSH-agent requirement.
4. Save the connection, or choose **Save & Connect**. Quick Connect uses credentials
   for the session only and does not create a saved profile.
5. Compare an unknown SSH host-key or untrusted RDP certificate fingerprint with
   your administrator's fingerprint before accepting it. Changed remembered
   identities trigger a separate warning. In the **Security** tab, **Forget trusted identity**
   removes the remembered exception.

Double-click a saved connection to connect. Context menus provide editing,
favorites, duplication, and deletion. After SSH rejects credentials, **Retry sign-in**
asks for fresh credentials instead of silently reusing the saved value. Check the
username/authentication option in Edit Connection if needed. Saving replacement
credentials remains optional; reconnecting alone does not delete the stored value.
Create folders from Add, and drag connection
rows into folders. The first release uses one level of folders. Search matches
names, hosts, users, protocols, and notes.

Session tabs can be reordered by dragging. Switching tabs does not reconnect or
terminate their sessions. The toolbar provides reconnect, disconnect, full screen,
and connection details. Closing a session disconnects it. Restored tabs remain
disconnected until you choose Reconnect; ad hoc connections are not restored.
Closing the last app window quits Farcast. Closing the window or choosing
Quit disconnects SSH/SFTP and RDP sessions and stops all embedded WireGuard tunnels
before the app exits.

### WireGuard for private RDP servers

Open **File → WireGuard Connections…** to import or create named WireGuard
profiles. In an RDP connection’s Add/Edit screen, choose a profile under
**Network → Connect via** and enter the private RDP server address. The tunnel
starts automatically and closes when its last RDP session disconnects. Multiple
RDP tabs can share a profile. This embedded userspace transport needs no separate
WireGuard app or macOS VPN setup and does not change other applications’ routes.
Keys follow the app’s existing credential storage policy. See
[WireGuard setup and limits](wireguard.md).

### SSH

- Password, encrypted private-key, and keyboard-interactive authentication.
- Embedded SwiftTerm terminal with Unicode, ANSI colors, resizing, terminal
  search, 10,000 scrollback lines, themes, and font zoom.
- Keepalives and explicit cancellation.
- Terminal copy/paste uses the normal macOS commands. Remote escape sequences
  cannot read or replace the local clipboard.
- In **Farcast → Settings → SSH terminal right-click**, choose **Show context menu**
  (default) or **Copy or paste automatically**. Changes apply to existing terminals.
  Right-click or Control-click opens Copy, Paste, Select All and Search with Google.
  Copy/search uses selected text, or the clicked output line when nothing is selected.
  Automatic mode copies a selection first; otherwise it pastes text on the live cursor
  line and copies a clicked output line elsewhere. Files/images are never pasted.
  Paste is disabled for output, scrollback and disconnected sessions. Cut is always
  disabled: a terminal selection cannot safely delete remote input. The cursor line
  approximates editable input; full-screen programs and wrapped prompts may differ.
  Mouse-aware programs receive right-click normally; hold Shift for local actions.
- SFTP opens on demand over the same authenticated SSH connection. No local shell
  process or SSH agent is started. Normal remote shell commands may also read/write
  files on the server.
- `~/.ssh/config`, ProxyCommand, jump hosts, forwarding, SSH certificates, and
  hardware-backed private keys are outside this release's supported configuration.

### SFTP file transfer

Connect with an existing SSH profile, then choose **Files** in its session tab.
**Split** keeps the terminal above the local and server file panels; **Terminal**
returns to the full terminal. Switching views preserves the same signed-in session.
Terminal and Split prioritise keyboard responsiveness during transfers. Files
uses the larger transfer pipeline for maximum throughput, which can help on
high-latency links. Switching back to Split may briefly wait for queued file data
to drain before the terminal becomes responsive.
The server must allow its SFTP subsystem for file transfer. If it refuses an
interactive terminal or ends the shell, the app checks SFTP and switches to
**Files** when available. **Terminal**, **Split** and terminal tools are disabled
for that connection. Reconnecting checks the server's capabilities again.

- The left panel starts at your actual Home folder. macOS asks for folder access
  the first time; approve Home to remember that permission for future sessions.
  Browse its subfolders or click the **Local Mac** heading to choose another local
  folder with the standard macOS folder picker. No credentials are added.
- The right panel starts in the server's SFTP home folder. Double-click folders,
  use the parent arrow, type a server path, or refresh either panel.
- Select files and folders with Command-click or Shift-click, then choose
  **Upload →** or **← Download**. Folders include their nested contents and empty
  folders. Selected items run sequentially; the batch stops at the first error.
- Right-click a selection for **Open**, **Rename**, **Cut**, **Copy**, **Copy Path(s)**,
  upload/download, **Paste into this folder**, **New Folder**, **Select All** and
  **Refresh**. Local items also offer **Reveal in Finder** and **Move to Trash**;
  server items offer confirmed permanent **Delete**, including folder contents.
- Copy/Cut uses a file buffer within the current SSH tab. Navigate or choose
  another local folder, then Paste on either side. It supports local-to-local,
  server-to-server and cross-side copies/moves. Copy Path writes newline-separated
  paths to the Mac clipboard; Paste does not read the Mac clipboard. Disconnect
  clears the file buffer. Copied local sources retain their selected-folder access.
- Same-side moves rename items when possible. Cross-side moves copy first and check
  source metadata again before removing originals. Moves require confirmation;
  completed batch items stay completed when a later item fails. Work with sources
  that other clients are not editing: SFTP metadata cannot establish a transactional
  snapshot or detect every concurrent content change.
- Opening a local file uses its default Mac application. **Open local copy…** on
  a server file downloads a snapshot into the app's temporary previews folder, then
  opens it locally. Edits are not uploaded automatically. Previews remain temporary
  local files until macOS removes them; do not rely on them for saved work.
- Upload/download file conflicts offer **Stop Transfer**, **Overwrite**, or
  **Overwrite All** for the remaining batch. Matching folders merge their contents;
  each conflicting regular file follows the chosen policy. Links and file/folder
  type mismatches are refused. Completed items remain if you stop the batch.
  Downloads publish atomically after completion; upload overwrites retain the old
  file until an atomic server rename succeeds (requires the OpenSSH POSIX rename
  extension). Unsupported servers retain the original and report an error.
  Same-side local copies and renames still refuse existing destinations.
  Failed folder operations may leave completed files or partial folders. Refresh to inspect.
- Drag selected local files/folders onto the server list to upload; drag server
  items onto the local list to download. Folder rows are destinations; dropping on
  the list background uses the displayed folder. Finder files/folders can also be
  dropped onto the server panel. Dragging copies items and does not remove sources.
- **Cancel** stops current file work and the remaining batch while retaining the
  SSH terminal/login. A pending network request drains before its file handle closes;
  up to the current 4 MiB upload window may finish. Interrupted uploads and recursive
  batches can leave partial destinations. Closing the tab disconnects everything.
  Completed rename/Trash actions cannot be undone by cancellation.

Symbolic links and special files are displayed but not followed. Recursive copying,
transferring or deleting a tree containing them fails its preflight without modifying
that tree's destination or removing its sources. Tree operations are limited to
20,000 items and 64 folder levels; remote listings require UTF-8 names and file-type
attributes. Server-to-server copies stream through a temporary local tree and need
sufficient local disk space. Local file publication requires hard-link support.
Resume and dragging server files directly into Finder remain unsupported.
File operation stalls disconnect SSH after 30 seconds without transfer progress;
the SSH connection remains usable after cancellation, including file-only sessions.
Real-server SFTP interoperability
remains unverified.

### RDP

- Embedded FreeRDP desktop, TLS, and Network Level Authentication (NLA).
- Certificate chains and host names evaluated through macOS Security.framework.
  Untrusted certificates require explicit approval; trust exceptions are scoped
  to host, port, and protocol. No accept-all certificate setting is enabled.
- BGRA framebuffer rendered through Metal. In **Display**,
  choose **Fit to window**, **Resize with window**, **100% with scrolling**, or
  **Match window at connection**. Fit scales the entire desktop; Resize with window
  also requests server resizing, falling back to scaling when unsupported. 100% uses
  one remote pixel per Mac point, with your chosen desktop dimensions. Choose a
  preset in **Resolution / Initial resolution**, or **Custom…** to enter width and
  height (200–8192 pixels each); existing custom sizes remain editable. Match window
  starts at the available desktop area and keeps that resolution until reconnecting;
  shrinking the window adds scrolling. Use scrollbars or Option-scroll to pan;
  ordinary scrolling goes to Windows. Display changes apply after reconnecting.
- In **Display**, enable **Open in full screen** to start on the current display after
  authentication. Enable **Use all monitors** for separate remote monitors matching
  the connected screens; these use their screen sizes instead of the preset/custom
  resolution. Mirrored displays are represented once. The session opens full screen
  only after the server confirms its geometry (and monitor layout for multiple screens).
  Missing or restricted confirmation keeps the desktop in the workspace with a notice.
- **Optimize for Retina** requests more source pixels and Windows UI scaling using
  each screen's backing density. The selected resolution becomes a **Logical size**
  in Mac points (custom units change to **pt**); stored numbers are preserved when
  toggling Retina. For example, a 1440 × 900 point region on a 2× display
  requests 2880 × 1800 pixels and 200% desktop scaling. Fixed/100% modes then map remote
  pixels to backing pixels. Legacy **Resize with window** already uses backing pixels
  and keeps its existing behavior. Windows policies and application DPI support can
  affect sharpness and UI size. More pixels require more memory and bandwidth.
- Click **Exit Full Screen** or press **Control–Command–F** to return without disconnecting;
  click **Enter Remote Desktop Full Screen** in the top-right toolbar to return to full
  screen on the same connection. This also works in detached session windows and after
  windowed startup. Confirmed multiple monitors are reused; a single display fits the
  current remote desktop resolution. Escape stays available to Windows. Display hotplug, rotation or topology changes return
  the session to the workspace: reconnect to use the new arrangement/density. Live
  multi-monitor topology updates are not implemented. Each monitor is limited to
  200–8192 pixels per side; the combined desktop is limited to 16384 pixels per side
  and 64 Mi pixels. Unusable layouts fail explicitly; try disabling Retina or all monitors.
  Physical multi-display/Spaces and real Windows mixed-DPI interoperability still need verification.
- Mouse, keyboard, scrolling, remote cursor, Unicode text input, and
  **Ctrl + Alt + Delete**.
- Optional text, file and folder clipboard sharing while the session is selected. It defaults off.
  Enable **Share clipboard** under **Devices & audio**, save and
  reconnect. Use Command+C / Command+V or Control+C / Control+V inside Windows.
  Command+C/X/V/A map to Windows Control shortcuts; otherwise Command maps to the Windows key;
  app shortcuts such as Command+W and Command+Q remain local.
  Copy files/folders in Finder and paste into Windows Explorer, or copy in Explorer
  and paste into Finder. Windows-to-Mac files download first; the desktop status
  reports when they are ready. Only complete batches enter the Mac clipboard.
  Transfers always copy; they do not delete the sources, even when Cut is used.
  The server must permit file clipboard redirection. Local files need readable
  access and Windows-compatible names; symbolic links and special files are refused.
  Remote temporary storage is limited to 8 GiB and 20,000 entries per batch.
  Copying something else, switching tabs or disconnecting cancels an unfinished
  download. Once ready, completed files remain available after disconnect while the app
  remains open and the clipboard owns them. Keep the app open until Finder finishes
  copying; these temporary files are not permanent storage. Last-write timestamps
  are preserved.
- Configure **Local folders** under **Devices & audio**. Use
  **Add Folder…**, choose the Mac folders, give each a unique drive name,
  save and reconnect. Windows exposes them in **This PC** and at
  `\\tsclient\DriveName`; no drive letter is assigned automatically. You can map that
  path to a drive letter using Windows Explorer if desired.
  **Read-only** defaults on. Turning it off allows the server to create, change,
  rename and delete the selected Mac folder's contents directly. No other Mac
  folders are automatically shared. **Choose another folder…** repairs unavailable
  access; **Remove** stops exporting it after reconnect. The server must permit
  drive redirection, independently of the clipboard setting. Symlinks/special files
  are unavailable, and advanced Windows filesystem features such as change
  notifications, byte-range locks and ACL editing are unsupported.
- Remote sound plays through this Mac by default. Turn off **Play remote sound on
  this Mac** under **Devices & audio** to mute it after reconnecting.
  The server must allow audio playback redirection. Microphone sharing is unavailable.
- US physical scan-code layout plus Unicode text input. Additional physical
  keyboard layouts, advanced IME behavior, live monitor-topology changes, hardware video
  decoding, microphone capture, RD Gateway, RemoteApp, smart cards and printers
  are not included in this release.

## Shortcuts

| Action | Shortcut |
|---|---|
| New connection | Command+N |
| Quick Connect | Command+K |
| Find in SSH terminal | Command+F |
| Reconnect | Command+Shift+R |
| Close selected session | Command+W |
| Show connection details | Command+Option+I |
| Settings | Command+, |


## Privacy and storage

- SwiftData stores folders and connection metadata in the application's local
  container. Passwords and private-key bytes are excluded from its schema.
- Keychain stores credentials by connection UUID, with device-only accessibility.
  If unavailable, credentials use owner-only, unencrypted files in
  `~/Library/Application Support/Farcast/Credentials` (directory 700, files 600).
  Deleting a profile also deletes its credential item; duplicating a profile does
  not silently duplicate credentials.
- UserDefaults stores appearance, restored tab IDs, and explicitly trusted server
  fingerprints. Profiles and trust preferences are local and do not sync.
- Live session objects own their native clients and view surfaces independently
  of SwiftUI view creation. Each native client's worker owns its library handles.
- SSH output is delivered with backpressure on the main thread. RDP snapshots
  use a latest-frame mailbox, so the UI cannot accumulate an unbounded frame queue.
- Cancellation resolves outstanding authentication dialogs and interrupts the
  transport. Diagnostics include state transitions, not credentials or terminal
  contents. There is no telemetry, updater, cloud account, or background service.


See [local testing](local-testing.md) for the optional test-server import workflow.

## Connection windows and file-access setup

Use **Pop Out Connection** in the active connection toolbar to move SSH/SFTP or RDP
to a separate resizable window. The existing connection stays authenticated. Use
**Return to Workspace**, or close that window, to return the live connection to its
tab. **Session → Close Session** disconnects and closes it. Session commands act on
the focused connection window. Window placement is not restored at next launch.

On first opening Files or Split, Farcast offers Full Disk Access setup. Open System
Settings → Privacy & Security → Full Disk Access, add Farcast with **+** if necessary,
and enable it. macOS may request a restart. Return to Farcast and click **Local Mac**
to choose Home or another folder; Home access is remembered. The shield button in
Local Mac reopens these settings. Choosing a folder alone lets you continue with
files macOS permits. Full Disk Access still requires a sandbox folder grant.

SFTP shows the average transfer speed of the current file in bytes per second.
The rate resets for each file in a folder transfer and disappears after the request
finishes or is cancelled. RDP file-clipboard messages share the bottom connection
status line, keeping the desktop height unchanged.
