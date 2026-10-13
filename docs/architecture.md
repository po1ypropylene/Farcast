# Architecture

## Platform and dependencies

Farcast is a native SwiftUI app for macOS 27+ and arm64 only. Xcode,
Package.swift and native builds share that minimum. SwiftData stores metadata;
Security.framework provides Keychain and certificate trust. SwiftTerm handles
terminal emulation, libssh2 SSH/SFTP, FreeRDP/WinPR RDP/NLA/channels, OpenSSL native
cryptography, Metal desktop frames, and wireguard-go/gVisor private session transport.
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
| Native/SSH, Native/RDP, Native/VNC | Independently written Objective-C protocol adapters |
| Native/Transport | Shared authenticated WireGuard socket handshake and redacted diagnostics |
| Networking/WireGuard | Independently written Go helper using pinned upstream modules |
| Tests/CoreTests, Integration, Maintenance | Core, protocol/UI coordination and disposable script checks |
| Tests/Fixtures | Blank disabled server-document example required by setup/import |

App source folders are under Farcast. Xcode's synchronized group includes
files there automatically; keep test-only tools/secrets outside it. Package.swift
builds only Domain/Persistence/Shared. Preserve existing SwiftData entity/property
identities; never reset the user's database during refactoring. The app module is
Farcast; bundle/storage identifiers are lowercase. See [branding](branding.md).

### Native adapter organization

SSH authentication, socket ownership and the worker loop remain in `SSHClient.m`.
Private categories hold terminal pumping (`SSHClient+Terminal.m`), SFTP request,
conflict and single-file transfer work (`SSHClient+SFTP.m`), and bounded recursive
preflight/copy/move/removal (`SSHClient+SFTPTree.m`). `SSHClientInternal.h` declares
shared private state and worker methods; it is excluded from the public bridge.
The split creates no extra sessions, authentication, queues or native-handle owners.
RDP folder provider/bookmark/device registration lives in `RDPDriveManager.m`;
root-confined filesystem requests and handles stay in `RDPDrive.m`.
Drive registration explicitly decodes FreeRDP's UTF-8 name/path when matching
the session registry; the full wire label is terminated UTF-8 and the short
device name is separate bounded ASCII.
Directory records use MS-RDPEFS wire layouts rather than native struct alignment:
the BothDirectory form has 93 bytes before its UTF-16 filename, with no reserved
byte between ShortNameLength and ShortName. Initial searches with no matches
return STATUS_NO_SUCH_FILE; exhausted continuations return STATUS_NO_MORE_FILES
and ignore the request's unused path/length. Root listing and file operations
share the existing RDP channel over both direct and WireGuard sockets.
One shared relative-path validator handles opens, renames and directory searches.
Directory opens and renames accept one trailing separator and store the canonical
path; interior empty components remain invalid. Open requests preserve directory
intent separately, so a trailing separator cannot open a regular file. Handle
identity/sharing checks and subsequent searches use the same canonical path.
Integration harnesses reuse one native source list and object-compilation helper.

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
SSH/RDP/VNC workers finish freeing their native handles and every launched WireGuard
helper exits. Protocol-wide worker/process groups also cover already-closed or
replaced tabs and helpers whose final lease was released. WireGuard shutdown rejects
new leases. Completion runs through the main run loop, including AppKit's nested
termination loop; the main actor never blocks waiting for protocol cleanup.

CredentialStore exposes synchronous Keychain operations to UI callers; authorization
can stall them. Worker-based I/O needs an explicit prompt/cancellation policy.
Injected credential lookup/preferences isolate workspace tests. Local builds preserve
the certificate requirement across updates; see [packaging](packaging.md).

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

Brand assets and regeneration are documented in [branding](branding.md); control
sizes, focus and accessibility rules are in [UI guidelines](ui-guidelines.md).
Terminal/Split background fills respect safe-area edges; the sidebar retains its
own native material. Sidebar destinations resolve WireGuard names from live metadata,
show missing references explicitly and expose full labels in tooltips.

The editor is a 540 × 600-point sheet capped to its presenting window, with a
128-point label column and 12-point gaps. General, Display, Devices & audio,
Terminal and Security tabs appear as applicable. Header/tabs/actions stay fixed;
one body scroll view handles short windows and long folder lists. Tab state starts
on General and falls back there if a tab becomes unavailable. All tabs share the
draft/credentials; switching tabs never reloads values. Invalid fields disable
saving and are reachable through marked tabs and a clickable footer hint.
Edit clears automatic text selection; New/Quick Connect focus Address.

Display labels map to existing stored modes: Resize with window is Fit plus
`dynamicResolution=true`; Fit to window is Fit plus false. 100% with scrolling
and Match window at connection retain their modes. Explicit preset selection
writes only width/height; unmatched dimensions use Custom and survive tab changes.
Startup full screen disables windowed mode/resolution controls while preserving
their values. Opening the editor never rewrites settings. Security can forget an
existing identity for the entered endpoint. Save applies settings on reconnect;
Save & Connect opens a session. Organization/notes persist without editor controls.

RDP negotiates software bitmap rendering for compatibility, then presents BGRA
frames through Metal and the latest-frame mailbox. Changing graphics negotiation
requires validating actual paint delivery, not authentication alone. Fit scales the desktop and optionally requests server resize;
100% maps one remote pixel to one Mac point; Match window waits for a laid-out viewport
and fixes that initial size (200–8192) until reconnect. Delivered server dimensions
remain authoritative. Fixed modes disable resize requests. Native NSScrollView clips
and pans, with pointer coordinates derived from the same render rectangle. Scrollbars
and Option-scroll pan locally; ordinary scrolling reaches Windows.

Optional `rdpLaunchFullScreen`, `rdpUseAllMonitors` and `rdpRetinaDisplay` metadata
preserves older profile identities; nil means the existing single-display defaults.
The startup display snapshot uses current AppKit screen IDs (not persisted enumeration
indices), ignores mirrored slaves, and converts logical geometry into signed primary-relative
remote monitor rectangles. Retina scales each monitor's pixel size and Windows desktop
scale separately, then reconstructs touching edges rather than multiplying global origins.
FreeRDP serializes initial monitor data/attributes. Device scale remains protocol-valid;
unknown physical dimensions are omitted. Geometry is validated in Swift and the native
adapter: 1–16 touching, non-overlapping monitors; each up to 8192 pixels per side; the
combined surface up to 16384 per side and 64 Mi pixels. Unsupported arrangements fail
with an explicit explanation, without silently dropping displays.

The session requests one remote desktop and waits for effective GDI dimensions. Multiple
full-screen targets also require a matching server Monitor Layout PDU; missing/mismatched
confirmation leaves a usable aggregate desktop in the workspace with an explanation after
five seconds. Each borderless native window maps one confirmed source region to its local
screen. All surfaces read one shared, immutable latest-frame mailbox; GPU uploads are cropped
per region and the windowed texture is retired during full screen. No per-monitor login or
full-desktop copy/queue is introduced. Input uses the inverse rendering transform and
positive framebuffer coordinates; cursor image/hotspot scale with that transform. Padding
rejects pointer input. Server geometry changes retire the full-screen targets before new
regions are presented. Exit Full Screen / Control–Command–F returns to the existing session;
Escape continues to reach Windows. The exit control has an opaque native background following local appearance.
Window activation retains one workspace clipboard owner.

The top-right RDP full-screen action observes the session's presentation/connection state
and reopens the existing authenticated desktop in attached or detached windows. Confirmed
multi-monitor sessions reuse their negotiated layout after checking that local displays
still match the connection snapshot. A single display fits the current server dimensions,
including after windowed resizing or windowed startup, without renegotiation. SSH keeps
the Mac-window full-screen action; RDP window full screen remains available through macOS
window controls. Re-entry is refused with a notice for unconfirmed or changed multi-monitor
geometry, and creates no new transport or authentication request.

Retina is opt-in for initial/fixed geometry, dynamic resize and Windows UI scaling.
Dynamic resize samples the usable viewport and its own backing conversion; Retina off
uses point-sized geometry and 100% desktop scale, while Retina on uses backing pixels once.
Window/backing changes refresh local drawables independently. Live resize flushes after
dragging ends; programmatic/backing changes use a replaceable 200 ms debounce.

`RDPResizeCoordinator` retains desired, pending submission and observed dimensions plus
local request IDs. One request awaits geometry at a time; newer intentions replace the
queued target and are reevaluated after an actual intermediate reset or finite deadline.
The native adapter recognizes `DISP_DVC_CHANNEL_NAME`, installs received capabilities,
validates area/count and sends on its worker. Channel loss retires caps/pending work;
session generation guards and local IDs reject stale callbacks. A failed/ignored target
is not resent endlessly; a changed viewport or new channel can try again. A DPI-only send
is handled once without claiming that dimensions confirm Windows UI scale.

Local fitting/input retain effective geometry while waiting. Actual desktop resets retire
obsolete textures and reject old-sized frames/pointer transforms before adopting new output.
There is a five-second observation/availability notice; send success is submission only.
Single-monitor full screen does not request the Monitor Layout PDU: that would make the
pinned FreeRDP activation state machine wait for a reply some hosts omit when multimon is
off. It uses actual GDI dimensions; multi-monitor confirmation remains required.
Multi-monitor geometry stays fixed until
reconnect; hotplug/rotation/topology changes exit to the workspace with a reconnect notice.
Live multi-monitor topology updates are unsupported. Reconnect creates new
caps, generation and monitor state; disconnect closes all targets and releases input.

Protocol contracts: [initial monitor data](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/a8029f8e-01e1-4f19-af67-bcad5bdef624),
[monitor attributes](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/8fb3a83c-f3e2-4a81-8824-8173af03b6bc),
[Display Control layout](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/ea2de591-9203-42cd-9908-be7a55237d1c), and
[pointer coordinates](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/2c1ced34-340a-46cd-be6e-fc8cab7c3b17).

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

Remote files stream in 256 KiB requests with at most eight ranges in flight to
private temporary trees (700/600), with an 8 GiB / 20,000-entry limit per batch
and a 30-second deadline for each outstanding response. Stream IDs retain each
range's offset and length; reordered responses use positional writes and short
responses request only their missing suffix. Progress reports received bytes.
Descriptor paths, collisions and file/directory conflicts are validated before
creation; links, absolute/traversal paths and partial batches are rejected. Finder
gets delayed file items after descriptors are validated, and standard file URLs
only after the entire batch completes. The main-actor
pasteboard bridge preserves a newer local copy and suppresses remote-file echoes.
AppKit file-URL data providers retain batches independently of the session.
Fulfillment waits on a native condition for at most five minutes; the RDP worker
signals completion/cancellation directly, independently of main-actor callbacks.
The channel loop and disk work continue while a paste consumer waits. Selection
changes/disconnect cancel partial downloads; completed clipboard files survive
disconnect while the app and pasteboard provider remain alive. After ownership
ends, cleanup waits 60 seconds for consumers already copying. App exit can leave
OS temporary files pending system cleanup; this is not persistent file storage.
Unidentified late format responses must drain before another request because that
PDU carries no request ID; stream IDs reject late file responses. A silent peer may
require reconnecting. Disk/codec work stays off the main actor. FreeRDP's Mac audio backend is bundled;
playback defaults on, microphone capture stays off and changes apply after reconnect.

## VNC protocol adapter

`Native/VNC/VNCClient` independently implements RFB 3.3/3.7/3.8 using the existing
OpenSSL dependency and macOS zlib. No external VNC client or copied protocol adapter
is used. Its cancellable worker owns the socket, TLS context, zlib stream and BGRA
framebuffer. Raw, overlapping CopyRect, Hextile and persistent Zlib encodings plus
DesktopSize are negotiated; unadvertised encodings, malformed rectangles and
oversized payloads fail closed. Bounds are 16384 per side / 64 Mi pixels, 4096
rectangles per update, 64 MiB compressed payload and 1 MiB queued keyboard/pointer
input. Frame publication copies an immutable snapshot into the existing latest-frame
mailbox. The same Metal view, inverse pointer mapping, scroll viewport and single
local-display full-screen presentation serve RDP and VNC; names of existing shared
classes and persistence properties remain intact.

VNC password authentication uses the specified DES challenge response (first eight
Latin-1 password bytes); no-auth is also supported. VeNCrypt 0.2 accepts X509None,
X509Vnc and X509Plain with TLS 1.2+. macOS evaluates the original hostname’s certificate,
and the endpoint-scoped trust prompt requires approval before authentication bytes.
An offered VeNCrypt mode is never downgraded to plaintext if no supported subtype
exists. Anonymous TLS and proprietary/ARD authentication are refused. Classic VNC
has no certificate identity or transport encryption; the editor explains this.
WireGuard uses the common token-authenticated socket handshake before RFB bytes,
with original host identity, independent destination leases, fail-closed tunnel
startup/exit and app-shutdown worker draining.

VNC reuses existing profile display/full-screen fields without a SwiftData schema
change. It exposes only fit/actual-size and single-display startup full screen;
server dimensions are authoritative and RDP-only device/resolution settings stay hidden.
VNC key events use X11 keysyms, including full Unicode scalars. Explicit clipboard
typing reads a snapshot on user action, normalizes CRLF/CR to Return, maps Tab,
rejects other controls and caps the batch at 16384 scalars. Worker-paced down/up
pairs at approximately 5 ms per character never send ClientCutText. Cancellation
cannot retract characters already delivered. Focus loss releases pressed input;
selection changes, disconnect and Ctrl+Alt+Delete cancel pending typing. Ctrl+Alt+Delete
is one queued sequence with releases in reverse order. ServerCutText is bounded
and discarded; no clipboard timer, file transfer or automatic clipboard reads
exist for VNC. Physical shortcuts use the existing US scan-code map translated to
keysyms; server keyboard/Unicode behavior remains a live interoperability limit.

Protocol sources: [RFB specification](https://www.rfc-editor.org/rfc/rfc6143.html)
and [RFB extensions including VeNCrypt and Zlib](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst).

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
truncate, delete-on-close and volume information. Empty query-directory replies
include the compatibility padding byte required by Windows at enumeration end;
the shared empty-response encoder also handles errors and cancellation.
Directory notifications, byte-range
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
reconnect behavior.

A session owns one SSH login and an SFTPController. Terminal/Files/Split only changes
presentation; SFTP opens lazily on the existing libssh2 session. Terminal channel,
PTY or shell refusal closes only that channel, then verifies SFTP on the same
authenticated transport before reporting a file-only connection. Shell EOF also
checks SFTP rather than ending usable file access. Transport errors, authentication
and trust failures still fail the connection; neither service available is an error.
Worker capability callbacks use the session's generation guard, select Files and
disable Terminal/Split and terminal tools. The native NSSegmentedControl enforces
per-segment disabled states; preserve that behavior when changing the mode picker.
Reconnect checks capabilities anew.
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
retain identical unacknowledged bytes. Transfers use the same login, worker and
protocol channel. Download handle-close cleanup
allows ten seconds for queued read-ahead replies (five for other handles) and pumps
terminal I/O while draining. Shutdown still interrupts socket waits immediately.
See [libssh2 exclusive-open flags](https://libssh2.org/libssh2_sftp_open_ex_r.html).

SFTP displays average bytes per second for the current file using a monotonic clock.
The worker emits a zero-byte start event for each leaf, including recursive trees;
new requests, completion, disconnect and cancellation clear or hide the rate. A periodic
UI refresh updates the average during stalls without changing worker backpressure.
First-use setup explains Full Disk Access and opens its System Settings pane. The
app never grants or probes protected personal data to infer that permission.
Full Disk Access does not replace sandbox folder grants; the Local Mac picker remains
necessary and Home bookmarks retain their existing scope.

Home comes from getpwuid, since NSHomeDirectory names the sandbox container. Explicit
NSOpenPanel read/write permission gates access; a Home security-scoped bookmark is
remembered/refreshed, while other folder scopes stay session-owned. The Local Mac
heading opens the same folder picker. Local operations run on
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
Dangling connection profile references fail closed instead of silently connecting directly.
One userspace helper/device per profile serves token-authenticated loopback TCP leases,
each restricted to its destination/AllowedIPs. Requests/keys use anonymous pipes;
diagnostics use allowlisted codes, never upstream config/keys/hosts. Blocking pipe work
runs off the main actor. Leases stop independently; the last closes the helper. Parent
EOF/signals close devices/listeners. Startup/dial/auth waits are bounded; edited profiles
require all leases to disconnect before new settings apply.

FreeRDP TCPConnect changes dialing only. Original host/port remain in TLS/NLA/trust;
endpoint redirects fail closed and multitransport is disabled. Destination IPs must
be within AllowedIPs. Configured DNS covered by those routes uses gVisor/WireGuard;
uncovered DNS uses ordinary UDP/TCP scoped to DNS only, with bounded A/AAAA queries
and TCP fallback. Literal destinations need no DNS. Resolving public addresses never
permits direct fallback. No system VPN/TUN/routes/DNS/admin changes occur.
See [WireGuard](wireguard.md) and [packaging](packaging.md) for lifecycle/sandbox rules.

### Protocol-independent tunnel startup

`RemoteSession.start` resolves a selected WireGuard profile before dispatching to
any protocol adapter. `Workspace.wireGuardSettings` owns metadata/key lookup, using
the same injectable credential provider as ordinary connection credentials.
The profile ID selects the existing process-wide `WireGuardTransport` registry;
SSH, RDP and VNC acquire independent destination/token leases on one helper/device.
Disconnect releases only that lease; the final lease stops the helper. Helper exit
fails every active lease and interrupts all adapters. Generation guards reject
late startup/status callbacks, and app shutdown drains native workers and helpers.

`Native/Transport/WireGuardSocket.h` implements the common token/acknowledgement
exchange, finite worker deadline, cancellation and redacted DNS/route diagnostics.
Adapters retain ownership of dialing, sockets and protocol negotiation. SSH dials
only the lease listener before libssh2 negotiation; its terminal and SFTP subsystem
retain one authenticated SSH transport. RDP overrides only TCP dialing and refuses
endpoint redirection. Trust always uses the original protocol/host/port. Missing
profiles/keys, invalid listener settings, failed tunnel DNS or uncovered destinations
never trigger direct dialing.

Future TCP protocols must use the same session startup and lease manager, then
consume the authenticated socket handshake in their adapter. They must retain
original endpoint identity and interrupt their worker when the lease fails. A
non-TCP protocol needs an explicit transport adapter; the existing helper provides
TCP destination leases, not a system VPN or arbitrary UDP forwarding.

## Build and maintenance

`.dependencies` contains reusable source/build/package/module/test caches;
`Vendor/Native` holds installed headers/libraries/helper. `.build` is disposable.
Integration runs use unique owner-only `.build/tests` trees and clean up their
processes/data/logs. Retain source fixtures only for distinct reproducible regressions.

The updater pins exact native/Swift/Go revisions, refuses downgrades, rolls back
manifests on resolution failure and invalidates stale native/sample-server products.
Resolved pins remain after build failure. Cleanup preserves dependencies and private
input, rejects tracked/redirected generated targets and never follows external links.
User-data reset is separate and destructive: it uses SecItemDelete without reading
secrets and refuses running app/helper processes, sudo and redirected paths.
See [development](development.md) for commands and cache relocation.

Packaging relocates the native dependency closure and ships notices. Local builds
retain a pinned certificate requirement with hardened runtime disabled; distribution
requires Developer ID, hardened runtime and notarization. Version.xcconfig owns
version/build metadata. Final bundle, loader, sandboxed-helper, mounted-DMG and
SHA256 checks are required; see [packaging](packaging.md) and [testing](testing.md).

## Unsupported features

SCP/WebDAV; SFTP resume/Finder download promises; SSH config/agent/jump hosts/
forwarding/certificates/hardware keys; RDP Gateway/RemoteApp/microphone/other devices/
hardware video; nested folders/cloud sync/updater. The app source license is
undecided. [Validation](validation.md) tracks remaining interoperability/release work.
