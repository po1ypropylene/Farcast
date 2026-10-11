# Architecture

## Platform and dependencies

Farcast is a native SwiftUI app for macOS 27+ and arm64 only. Xcode,
Package.swift and native builds share that minimum. SwiftData stores metadata;
Security.framework provides Keychain and certificate trust. SwiftTerm handles
terminal emulation, libssh2 SSH/SFTP, FreeRDP/WinPR RDP/NLA/channels, OpenSSL native
cryptography, Metal desktop frames, and wireguard-go/gVisor private RDP transport.
Pins, checksums and licenses live in the build scripts, Go manifests and ThirdParty.
No runtime Homebrew, external protocol client or SSH agent is required.

## Source map

| Folder | Responsibility |
| --- | --- |
| App | Scene composition and lifecycle |
| Domain | Drafts, protocols, authentication, display choices, session state |
| Persistence | SwiftData models and metadata import |
| Shared/Security | Credential stores and endpoint trust |
| Shared/Prompting | UI presentation and worker responses |
| Shared/Testing | Bounded, redacted test-document decoding |
| Features/Workspace | Sidebar, overview, tabs, coordination and shared controls |
| Features/Connections | Profile editor, explicit key picker, import preview |
| Features/Sessions | Lifecycle, prompts, panes, diagnostics and SFTP controller |
| Features/Settings | Appearance and tab restoration |
| Features/WireGuard | Profile library, transport leases and packaged helper probe |
| Protocols/SSH | Persistent terminal view/delegate |
| Protocols/RDP | Metal view, scrolling, input and latest-frame mailbox |
| Native/SSH, Native/RDP | Independently written Objective-C protocol adapters |
| Networking/WireGuard | Independently written Go helper using pinned upstream modules |
| Tests/CoreTests, Integration, Maintenance | Core, protocol/UI coordination and disposable script checks |
| Tests/Fixtures | Blank disabled server-document example required by setup/import |

App source folders are under Farcast. Xcode's synchronized group includes
files there automatically; keep test-only tools/secrets outside it. Package.swift
builds only Domain/Persistence/Shared. Preserve existing SwiftData entity/property
identities; never reset the user's database during refactoring. The app module is
Farcast, with separate lowercase bundle/storage identifiers. Explicit rename migration
is described below.

## Session ownership and cancellation

Workspace is main-actor observable state and owns RemoteSession objects. A session
snapshots its ConnectionDraft and owns persistent native clients/surfaces. SwiftUI
pane recreation never reconnects. Generation IDs reject callbacks from earlier attempts.
Closing disconnects; selection releases pressed desktop input and limits clipboard
sharing to the selected RDP session. Reconnect reloads saved metadata, resolves
credential/validation failures before replacing the old session, and replaces the tab
at its existing index. Background reconnect retains the selected tab. Ad hoc/deleted
profiles retain their snapshot. Only persistent tabs enter restoration preferences;
restored tabs remain disconnected. Dragging inserts a tab before its destination.

Each native worker owns its handles and bounded input/work queues. SSH sends output
with main-thread backpressure. RDP uses a latest-frame mailbox, dropping superseded
frames instead of building an unbounded UI queue. Trust/interactive callbacks wait on
single-use PromptWaiter responses while the main actor presents sheets. Cancellation
resolves pending prompts, interrupts transport work, invalidates callbacks and stops
clipboard timers. Never wait for workers/prompts on the main actor.

A popped-out session retains its Workspace-owned RemoteSession, native surfaces and
transport. A stable window slot follows replacement session IDs on reconnect. Only
attached sessions appear in the main tab strip; closing the detached window returns
its live session, while Close Session disconnects and removes it. Window focus chooses
the single RDP clipboard/input owner and the Session menu target. Prompts are routed
to the session's presenting window. Detached placement is temporary; restoration still
stores profile IDs and restores disconnected tabs in the main window.

Closing the last app window requests termination. Quit and window close use the same
asynchronous shutdown: save tab restoration metadata, reject new connections/prompts,
cancel existing prompts and disconnect all sessions, then reply to AppKit only after
SSH/RDP workers finish freeing their native handles and every launched WireGuard
helper exits. Protocol-wide worker/process groups also cover already-closed or
replaced tabs and helpers whose final lease was released. WireGuard shutdown rejects
new leases. Completion runs through the main run loop, including AppKit's nested
termination loop; the main actor never blocks waiting for protocol cleanup.

CredentialStore currently exposes synchronous Keychain operations used by UI callers.
Certificate-backed local builds preserve the recorded code identity across updates,
avoiding the repeated approval caused by changing ad-hoc hashes. Existing items may
need one final grant for that transition. Credential contents/ACLs are unchanged.
Other Keychain authorization can still stall synchronous callers; worker-based credential
I/O with explicit prompt/cancellation policy remains an open improvement. Injected
credential lookup and preferences let workspace tests avoid real Keychain/user defaults.

## Storage and trust

SavedConnection/ConnectionFolder/SavedWireGuard contain metadata, not secrets. Optional
wireGuardID and rdpDisplayMode preserve existing schema identities; absent/unknown
modes use Fit. audioPlayback defaults true for older profiles. Credential coding retains
compatibility when adding optional tunnel fields. Device-only Keychain stores secrets by
UUID. When unavailable, owner-only unencrypted files under Library/Application Support/
Farcast/Credentials provide the disclosed development fallback (directory 700,
files 600, atomic writes). Existing local records remain authoritative. Quick Connect
never saves secrets/profiles; duplication does not copy credentials; profile deletion
removes its credential item. No automatic Keychain export is used.

Trust preferences are separate and scoped to protocol/host/port. SSH verifies a host
key before authentication; RDP evaluates certificate chain and original hostname with
Security.framework. Unknown/changed identities require explicit approval. TLS/NLA stay
on, plaintext legacy RDP and accept-all trust stay off.

Test documents are bounded temporary secret-bearing input with redacted errors.
Import creates new metadata in Test Servers, skips existing UUIDs, offers separate
credential saving, and never connects or trusts imported fingerprints automatically.
See [local testing](local-testing.md) for protected-input rules.

### Explicit library migration

Farcast uses `com.peterpo.farcast` and a new sandbox; it never silently opens or
resets the previous library. File → Import Existing Library requires an empty
destination and no session tabs. A user-selected Data/Library directory supplies
the old default.store and journal companions, optional local credential files and
an allowlisted preference subset. The previous app must be quit. Imports copy the
database into an owner-only temporary tree before SwiftData opens it, because
opening an original store can migrate/checkpoint it. Entity/property identities and
all metadata IDs/raw optional values/dates are retained across the module rename.
Original input remains untouched; symbolic-link components and oversized input fail
closed, and errors omit input paths/values.

Local secrets are copied only with explicit opt-in into Farcast's 700/600 atomic
file store. Credential input is decoded before destination writes; credential writes
are rolled back if metadata saving fails. An orphaned destination credential prevents
replacement. Keychain contents are never copied or exported. Appearance, restoration
and explicitly imported trust decisions are retained; unrelated preferences and old
security-scoped grants are excluded. RDP export metadata remains but grants must be
reselected when macOS refuses them. No sessions automatically connect. Historical
bundle/path strings are restricted to migration recognition and test provenance.

## UI and desktop presentation

Terminal background fills respect every safe-area edge, including the navigation
split view's sidebar boundary. Terminal and Split modes use the same bounded fill;
the connection sidebar retains its native material independently of terminal themes.

The grouped connection Form is the editor's only scrolling owner, with fixed header
and actions. It omits organization/notes controls in all modes while preserving existing
data. Full-width disclosure rows announce their state. Server address and port are
separate; validation rejects combined host:port while preserving IPv6. Tabs use
compact 28-point capsule Liquid Glass, normal body text and independent
22-point close targets. Icon actions use 24-point borderless native buttons; other
controls use regular native bordered/glass styles without enlarged labels or touch
margins. The Mac interface follows Safari proportions; future iPad sizing is separate.
Sidebar RDP hosts append the selected
WireGuard profile name from the live metadata query; missing references explicitly
show an unavailable tunnel. Long destination labels expose the full text in a tooltip. See [UI guidelines](ui-guidelines.md).

RDP negotiates software bitmap rendering: enabling the graphics pipeline authenticated
but delivered no visible paint callbacks on a supplied server. This is a bounded
interoperability workaround, not a diagnosis for every server. Metal/BGRA/latest-frame
ownership stays intact. Fit scales the desktop and optionally requests server resize;
100% maps one remote pixel to one Mac point; Match window waits for a laid-out viewport
and fixes that initial size (200–8192) until reconnect. Delivered server dimensions
remain authoritative. Fixed modes disable resize requests. Native NSScrollView clips
and pans, with pointer coordinates derived from the same render rectangle. Scrollbars
and Option-scroll pan locally; ordinary scrolling reaches Windows.

The worker retains clipboard updates before channel attachment and advertises after
MonitorReady. The selected session synchronizes before paste and on its timer.
Command+C/X/V/A map to Windows Control shortcuts after releasing forwarded Command;
app shortcuts remain local. Text and file sharing are opt-in.
The native clipboard adapter negotiates [MS-RDPECLIP](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeclip/cbc851d3-4e68-45f4-9292-26872a9209f2) file streaming, relative file
lists, locks and large-file ranges. Finder file URLs retain their security scopes;
regular files and folders are traversed/read on the RDP worker with no-follow
component opens, bounded entries/ranges and source identity/metadata checks.
Locked local snapshots survive clipboard replacement until unlock (at most eight).
Clipboard transfer is separate from folder redirection; source data must remain
quiescent and transfers use copy semantics. Last-write timestamps accompany file
descriptors and are restored after staging (directories last).

Remote files stream in 256 KiB requests to private temporary trees (700/600), with
an 8 GiB / 20,000-entry limit per batch and a 30-second no-progress timeout.
Descriptor paths, collisions and file/directory conflicts are validated before
creation; links, absolute/traversal paths and partial batches are rejected. Finder
gets standard file URLs only after the entire batch completes. The main-actor
pasteboard bridge preserves a newer local copy and suppresses remote-file echoes.
AppKit file-URL data providers retain completed batches independently of the
session. They fulfill from existing local paths without network waits. Selection
changes/disconnect cancel partial downloads; completed clipboard files survive
disconnect while the app and pasteboard provider remain alive. After ownership
ends, cleanup waits 60 seconds for consumers already copying. App exit can leave
OS temporary files pending system cleanup; this is not persistent file storage.
Unidentified late format responses must drain before another request because that
PDU carries no request ID; stream IDs reject late file responses. A silent peer may
require reconnecting. Disk/codec work stays off the main actor, and the existing
input/latest-frame pipeline remains unchanged.
FreeRDP's Mac audio backend is
bundled, playback defaults on, and microphone capture stays off. Changes apply after
reconnect; real-server clipboard/audio policies still need broader verification.

## RDP selected-folder redirection

Per-connection exports store drive names, read-only flags and security-scoped
bookmarks in optional `SavedConnection.rdpFolderExports` metadata. Existing entity
and property identities remain intact; missing metadata means no exports. Unreadable
metadata blocks connection until the user explicitly resets/reselects it. The folder
picker grants access only to selected directories, and each native device retains
its security scope until queued work and open handles retire. Stale/unresolvable
bookmarks fail closed and require choosing the folder again.

An independently implemented [MS-RDPEFS](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpefs/d8b2bc1c-0207-4c15-abe3-62eaa2afcaf1)
backend supplies explicit filesystem devices through FreeRDP's addin interface.
Automatic drive/home/hotplug exports are disabled. Core context initialization
preserves the process-wide custom provider across concurrent connections; the
common client constructor would replace it with the stock drive backend. Unicode
full names travel in device data, with bounded ASCII fallback names. Each device
has a serial worker and a pinned root directory descriptor. Checked relative paths,
no-follow component opens and handle identity checks reject traversal, links and
special files. Opens honor access/share modes; read-only denies every create,
write, overwrite, truncate, rename, delete, attribute and mutating control request.
Disconnect cancels work and does not execute pending delete-on-close operations.

Supported requests cover create/open/close, 64-bit-offset reads/writes, directory
pagination, basic/name/standard/all metadata, timestamps/attributes, rename,
truncate, delete-on-close and volume information. Directory notifications, byte-range
locking, security-descriptor updates and arbitrary device controls return unsupported;
this is folder access, not a complete Windows filesystem emulation. Up to 16 named
exports, 1,024 handles/device, 20,000 listing entries and 1 MiB I/O requests bound
resource use. Windows policy may disable device redirection independently of
clipboard sharing. Writable exports directly modify the selected Mac files.

## Shared SSH and SFTP

The persistent SSH surface subclasses SwiftTerm's native view for local right-click
actions. A live UserDefaults preference selects a native context menu (default) or
automatic copy/paste. Selected text takes precedence; otherwise the clicked visible
output line is copied, or text is pasted when clicking the connected terminal's
cursor row at the live viewport. This is a cursor-line approximation, not remote
editability detection. Scrollback and disconnected/file-only sessions cannot paste.
Cut stays disabled because local terminal selection has no safe remote deletion
operation. Mouse-aware programs retain button reporting; Shift overrides it locally.
Paste rejects file URL/legacy file-list representations even alongside text and uses
SwiftTerm's text paste encoder for bracketed-paste handling. Remote clipboard escape
requests remain refused. Explicit Google search passes only the chosen text to the
default browser; opening a menu neither reads text clipboard data nor launches search.

After host-key verification, the SSH worker queries the server's allowed sign-in
methods with bounded nonblocking retries. Password prefers SSH password and can
fall back once to advertised keyboard-interactive. It supplies the selected password
once to a recognized masked password prompt; codes, visible/unrecognized prompts
and all explicit Interactive prompts use the existing cancellable UI coordinator.
Cancelling a challenge disconnects; the temporary password reference clears after
sign-in and on every cleanup path. Private-key selection never falls back to another
credential type. A NULL method list is accepted only when libssh2 confirms successful
none authentication. See [libssh2 authentication](https://libssh2.org/libssh2_userauth_list.html).

Credential rejection has a worker callback guarded by the session generation.
Reconnect then replaces the tab in place and requests fresh credentials, bypassing
the saved lookup for that retry. Explicit Interactive retries ask the server again
without a separate password dialog. Stored credentials are changed only through the
existing user-controlled saving flow; transport/identity failures retain normal
reconnect behavior. No persistent model identity changes are involved.

A session owns one SSH login and an SFTPController. Terminal/Files/Split only changes
presentation; SFTP opens lazily on the existing libssh2 session. Terminal channel,
PTY or shell refusal closes only that channel, then verifies SFTP on the same
authenticated transport before reporting a file-only connection. Shell EOF also
checks SFTP rather than ending usable file access. Transport errors, authentication
and trust failures still fail the connection; neither service available is an error.
Worker capability callbacks use the session's generation guard, select Files and
disable Terminal/Split and terminal tools. Reconnect checks capabilities anew.
Subsystem refusal with a usable shell leaves the terminal available. The worker
services terminal I/O/resize between file
chunks and socket waits. Callbacks check generation and operation IDs. Listings are
bounded to 20,000 UTF-8 entries; trees to 20,000 items/64 levels. Symlinks/special files
are displayed but refused by recursive preflight. Directory/list/handle/no-progress
waits are bounded. Genuine transport/cleanup failure can disconnect shared SSH.
Without a shell, file waits skip terminal pumping; idle extended-stream reads on
the SFTP channel drain SSH control/keepalive packets and detect transport closure.
Standard-stream bytes remain exclusively owned by SFTP. See
[libssh2 channel streams](https://libssh2.org/libssh2_channel_read_ex.html).
The session accepts an injected file controller for isolated UI/transport checks.

New uploads first attempt exclusive creation; only a failed create checks the existing
destination and offers overwrite approval. Approved replacements retain private staging
and OpenSSH atomic rename. Exclusive creation never opens an existing destination,
including symlinks. Recursive remote preflight reuses complete READDIR size/type/time
snapshots, falling back to LSTAT when fields are absent. Every transfer still rechecks
source metadata immediately before copying, and moves rescan before source deletion.
Buffers are file-sized within 4 MiB upload / 1 MiB download maxima. Uploads refill
after a quarter-window has been acknowledged, reducing memmove work; EAGAIN retries
retain identical unacknowledged bytes. These changes remove redundant requests and
allocations without a second login, worker or protocol channel. Download handle-close cleanup
allows ten seconds for queued read-ahead replies (five for other handles) and pumps
terminal I/O while draining. Shutdown still interrupts socket waits immediately.
See [libssh2 exclusive-open flags](https://libssh2.org/libssh2_sftp_open_ex_r.html).

SFTP displays average bytes per second for the current file using a monotonic clock.
The worker emits a zero-byte start event for each leaf, including recursive trees;
new requests, completion, disconnect and cancellation clear or hide the rate. A periodic
UI refresh updates the average during stalls without changing worker backpressure.
First-use setup explains Full Disk Access and opens its System Settings pane. The app
neither silently grants nor probes protected personal data to infer that permission.
Full Disk Access does not replace sandbox folder grants; the Local Mac picker remains
necessary and Home bookmarks retain their existing scope.

Home comes from getpwuid, since NSHomeDirectory names the sandbox container. Explicit
NSOpenPanel read/write permission gates access; a Home security-scoped bookmark is
remembered/refreshed, while other folder scopes stay session-owned. The plain Local
Mac heading opens the same folder picker with compact Mac sizing; both file-pane
headings and navigation rows use matching minimum heights. Local operations run on
workers with O_NOFOLLOW, cancellation and retained scopes. No broad filesystem
entitlement is used. Multi-selection jobs run sequentially and stop on the first error.
File buffers capture session-local paths/scopes; Paste never reads system clipboard.
Copy Path alone writes requested paths. Disconnect clears buffers and late drop callbacks.

Regular-file transfer conflicts ask Stop/Overwrite/Overwrite All; the last is scoped to
one batch. Real folders merge; links/type mismatches fail. Downloads fsync sibling
staging then atomically publish; exclusive new files use hard links. Overwrite uploads
stage exclusively then use posix-rename@openssh.com; unsupported servers preserve the
original and fail, with no truncate/delete fallback. Same-side local copy/move and
rename retain no-overwrite behavior. Cancellation attempts staging cleanup; interruption
can leave uploaded partial files, completed tree leaves or remote staging.

Files mode uses refilled bounded 4 MiB upload and 1 MiB download windows, capped
by file size. Terminal/Split mode offers at most 128 KiB per upload and 32 KiB per
download read; libssh2's fourfold download read-ahead is then bounded to 128 KiB.
This limits file bytes ahead of interactive packets on the shared TCP stream.
Mode changes use an atomic scheduling hint; only the worker accesses native handles.
Previously queued bulk bytes must drain before the smaller budget takes effect.
The upload budget can change only after a positive acknowledgement; refills occur
after a quarter-budget (at least 32 KiB) and never replace unacknowledged bytes.
EAGAIN retries preserve unacknowledged bytes/buffer lengths under
[libssh2's write-ahead contract](https://libssh2.org/libssh2_sftp_write.html). TCP_NODELAY
and captured SFTP readiness directions avoid terminal pumping changing pending wait
requirements. Visible-terminal waits poll at most ten milliseconds between worker
checks. Terminal writes retain a stable bounded snapshot across EAGAIN, while new
keystrokes append behind it. Cancel stops refilling, drains submitted work and closes its handle,
retaining the authenticated terminal and idle SFTP channel. It can finish the current
4 MiB window. Terminal pumping/backpressure and throttled progress stay intact.

Moves copy then recheck metadata before deleting sources; same-side moves prefer
exclusive rename. Metadata checks require quiescent sources and cannot guarantee a
transactional snapshot or detect every concurrent same-size change. Server-to-server
copies stream through temporary local trees. Completed work remains after later failure.
Remote Delete is confirmed/permanent; local deletion uses Trash. Remote Open downloads
a temporary snapshot for a local application with no automatic upload; the OS owns its
later cleanup. Local publication needs filesystem hard-link support.

List itemProvider/onInsert plus folder/background drop handlers support internal
session tokens and Finder file URLs with retained scopes/provider lifetime. Text is
never treated as paths. Drops copy and reuse recursive/conflict rules. Finder download
promises and actual production drag/sandbox interoperability remain deferred/unverified.

## Embedded WireGuard

Saved profiles hold bounded single-peer metadata; keys use existing credential storage.
Dangling RDP profile references fail closed instead of silently connecting directly.
One userspace helper/device per profile serves token-authenticated loopback TCP leases,
each restricted to its destination/AllowedIPs. Requests/keys use anonymous pipes;
diagnostics use allowlisted codes, never upstream config/keys/hosts. Blocking pipe work
runs off the main actor. Leases stop independently; the last closes the helper. Parent
EOF/signals close devices/listeners. Startup/dial/auth waits are bounded; edited profiles
require all leases to disconnect before new settings apply.

FreeRDP TCPConnect changes dialing only. Original host/port remain in TLS/NLA/trust;
endpoint redirects fail closed and multitransport is disabled. RDP destination IPs must
be within AllowedIPs. Configured DNS covered by those routes uses gVisor/WireGuard;
uncovered DNS uses ordinary UDP/TCP scoped to DNS only, with bounded A/AAAA queries
and TCP fallback. Literal destinations need no DNS. Resolving public addresses never
permits direct RDP fallback. No system VPN/TUN/routes/DNS/admin changes occur.
See [WireGuard](wireguard.md) and [packaging](packaging.md) for lifecycle/sandbox rules.

## Build and maintenance

`.dependencies` retains native source/build trees, Go caches, Xcode package downloads,
test Python and the reproducible RDP sample server. `Vendor/Native` holds installed
headers/libraries/helper. `.build` is entirely disposable. Test runs under `.build/tests`
are unique, owner-only and removed on exit with their processes/logs/data. Keep source
fixtures that exercise distinct regressions; discard one-off generated review artifacts.

The updater compares numeric stable bare/v/V tags, refuses downgrades, pins exact
native/Swift/Go revisions, rolls back manifests on resolution failure and invalidates
outdated native/sample-server products. Successfully resolved pins remain after a build
failure; upstream notice changes still need review. Project cleanup preserves dependencies
and protected input, rejects tracked/redirected generated targets and never follows
external links. User-data reset is a separate explicit destructive action scoped to
current-bundle Library/preferences/credential service, using SecItemDelete without
reading secrets; it refuses a running app/helper, sudo and redirected paths.

Packaging relocates the native closure and ships notices. Local certificate-signed builds disable
hardened runtime and recreate the generated app before final signing. Distribution
requires Developer ID/hardened runtime/notarization. Version.xcconfig is the single
version source; DMGs use built metadata. Final bundle/loader/sandboxed-helper checks
are required. See [development](development.md), [packaging](packaging.md) and
[testing](testing.md) for procedures.

Deferred: SCP/WebDAV, SFTP resume/Finder download promises, SSH
config/agent/jump hosts/forwarding/certificates/hardware keys, RDP Gateway/RemoteApp/
microphone/other devices/multiple monitors/hardware video, nested folders/cloud sync/
updater. The source license is undecided; synthetic passes do not establish production
interoperability or distribution readiness.
