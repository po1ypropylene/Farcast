# Architecture

## Platform and dependencies

Farcast is a native SwiftUI app for macOS 27+ and arm64 only. Xcode,
Package.swift and native builds share that minimum. SwiftData stores metadata;
Security.framework provides Keychain and certificate trust. SwiftTerm handles
terminal emulation, libssh2 SSH/SFTP, FreeRDP/WinPR RDP/NLA/channels, OpenSSL native
cryptography, Metal desktop frames, and WireGuard/OpenVPN with gVisor private session transport.
Farcast's original source is MIT-licensed in LICENSE. Dependency pins, checksums
and separate licenses live in the build scripts, Go manifests and ThirdParty.
No runtime Homebrew, external protocol client or SSH agent is required.

Protocol input failures must not silently leave a session usable after losing
ordered bytes or releases. SSH queue overflow ends the transport; PTY resize
retries retain submitted dimensions until completion before sending newer desired
geometry. RDP input send failure ends the current drain/transport and enters the
existing bounded recovery policy, without retrying uncertain input delivery.
Forwarded Command equivalents balance physical nonmodifier keys immediately,
because AppKit may omit their key-up. Local shortcut routing is unchanged.

libssh2 uses an immutable upstream master snapshot for unreleased security fixes;
the preparation script and third-party inventory record its full commit. Dependency
refreshes resolve master explicitly, and installed native outputs carry a hash of
the preparation script so changed pins or flags require rebuilding.

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
| Features/WireGuard | Shared VPN profile library, transport leases and packaged helper probe |
| Protocols/SSH | Persistent terminal view/delegate |
| Protocols/RDP | Metal view, scrolling, input and latest-frame mailbox |
| Native/SSH, Native/RDP, Native/VNC | Independently written Objective-C protocol adapters |
| Native/Transport | Shared authenticated WireGuard socket handshake and redacted diagnostics |
| Networking/VPN | Shared Go helper and gVisor stack with WireGuard and OpenVPN engines |
| Networking/OpenVPN | Independently written C++ OpenVPN Core adapter and private packet bridge |
| Tests/CoreTests, Integration, Maintenance | Core, protocol/UI coordination and disposable script checks |
| Tests/Fixtures | Blank disabled server-document example required by setup/import |

The shared VPN helper lives in `Networking/VPN`: `main.go` owns request dispatch,
session listeners and transport lifetime, `wireguard.go` owns WireGuard device
setup, `openvpn.go` bridges OpenVPN Core, and `dns.go` owns shared DNS policy.
Both engines use the Go/gVisor stack; C++ stays behind the OpenVPN packet bridge.
The executable/signing identity and JSON messages remain compatible, as do saved
profile/schema and credential identities. The source-only directory migration is
documented in [development](development.md#vpn-helper-source-migration).

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
The split creates no extra sessions, authentication or native-handle owners.
`SSHClient+Forwarding.m` owns rule commands, listeners, bounded socket/channel flows,
SOCKS5 parsing and half-close handling on that same worker.
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

Connection Details opens as a trailing overlay by default, preserving the session viewport.
A persistent workspace pin preference reserves 301 points only while details are
visible, allowing the existing opt-in RDP resize path to follow the reduced viewport.
Main and detached windows share this layout without reparenting their native surface.
Connection Details retains a bounded, in-memory activity history per session. It
records VPN lease transitions, protocol status/errors, requested initial RDP geometry,
Display Control submission/results, observed server geometry and presentation changes.
Submission is distinct from server-confirmed geometry; VPN readiness is lease readiness.
The latest connection failure remains visible during recovery and after disconnect.
Logs exclude credentials, clipboard/terminal contents and shared-folder paths.

Each native worker owns its handles and bounded input/work queues. SSH sends output
with main-thread backpressure. RDP uses a canonical framebuffer in a lock-owned latest-frame mailbox. Native
workers publish immutable packed damage patches; Swift Data copy-on-write protects
snapshots retained by renderers. A bounded 64-generation rectangle history lets each
surface union missed damage; old generations, resize and new/resumed surfaces use
a full upload. Superseded publications do not build an unbounded UI queue. Mailbox publication coalesces one
main-queue notification for all live weakly registered surfaces. Rendering follows
frame delivery and native invalidation rather than MTKView's periodic window-bound
display link, which can stop after closing a full-screen window during reparenting.
Uploads are paced to the destination screen's maximum refresh rate, with one
pending redraw and one GPU command buffer per surface. GPU completion releases
shared-texture ownership asynchronously; updates received meanwhile replace the
mailbox frame. Explicit draws use MTKView's drawable lifecycle; drawable resources
are released on window transfer rather than per frame. Presentation suspension
cancels scheduled draws and is independent of the disabled periodic link.
Trust/interactive callbacks wait on single-use PromptWaiter responses while the main
actor presents sheets. Cancellation
resolves pending prompts, interrupts transport work, invalidates callbacks and stops
clipboard timers. Never wait for workers/prompts on the main actor.

RDP transport loss is published before native channel/drive cleanup. A per-client
completion callback starts recovery only after that worker retires. Established
sessions retain their credential in memory and retry with a fresh native client and
WireGuard lease in the same tab after 2, 5 and 10 seconds. Generation guards reject
retired callbacks; manual disconnect/close/quit cancels pending retries and releases
the retained credential. Initial failures, rejected authentication/trust and explicit
server logoff/policy termination do not automatically retry. A connection must remain
established for 60 seconds to replenish the retry budget, preventing rapid flapping
from retrying indefinitely. This is fresh authentication, not RDP reconnect-cookie
resumption; server policy determines whether the existing desktop is restored.

Direct RDP TCP sockets use a 15-second keepalive idle interval, three probes spaced
five seconds apart, and Darwin's 20-second retransmission drop timeout. The latter
supplements FreeRDP's TCP_USER_TIMEOUT setting, which is unavailable on macOS.
A main-actor health task samples atomic worker progress every five seconds; 30 seconds
without worker progress marks the session Stale, disables input/clipboard, exits full
screen and interrupts the transport using a duplicate socket descriptor protected
by the native lock. No frame-arrival deadline or synthetic keyboard/mouse input is
used. Workers retain handle ownership and finish cleanup before a retry begins.
An uninterruptible local file operation can delay cleanup and therefore recovery.

A popped-out session retains its Workspace-owned RemoteSession, native surfaces and
transport. A stable window slot follows replacement session IDs on reconnect. Only
attached sessions appear in the main tab strip; closing the detached window returns
its live session, while Close Session disconnects and removes it. New desktop windows
use the observed remote pixel dimensions divided by the destination Retina scale when
enabled, plus measured toolbar/status chrome, capped to that screen's visible frame.
Window focus chooses the single RDP clipboard/input owner and the Session menu target. Prompts are routed
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
own native material. Sidebar destination subtitles show user@host via VPN name for
routed profiles, resolve VPN names from live metadata, show missing references
explicitly and expose full endpoints in tooltips and Get Info. Folder identity, optional
parent ID and collapse state live in SwiftData; legacy folders default to expanded roots.
Legacy favorite and favoriteOrder fields remain stored for library compatibility; the UI ignores them.
Search includes ancestor folder names and temporarily reveals matching branches
without changing saved collapse state. Removing a folder reparents its children and profiles
without deleting credentials. Native List selection retains system accent and inactive styling.
Protocol text badges remain on the trailing edge, and protocol icons lead each row.
The Add button and empty-sidebar context menu share their creation/import actions.
The unused sidebar area below
visible content accepts connection drops to the root; measured row bounds keep this target
separate from folder labels.
SSH output sets a per-session unread flag for background tabs, cleared on session selection;
this uses the existing backpressured main-thread delivery and records no terminal contents.
SSH config import reads only a user-selected, bounded UTF-8 file and previews metadata.
It never follows includes, executes directives or loads referenced key files. Proxy-based
hosts are excluded; unsupported options are not translated. Import creates untrusted
password-authentication profiles and does not save credentials or connect.

The VPN library uses an 820-point sheet with a 210-point sidebar and compact,
bordered form cards. An in-memory draft and baseline include secrets without
encoding them into metadata. Selection, New and Done protect dirty edits with
Save/Discard/Cancel; protocol changes explicitly clear the protocol-specific draft.
Validation runs on field blur and Save, revealing advanced fields when necessary.
Imported filenames remain transient; OpenVPN summaries use only parsed remote and
transport directives outside secret blocks. Secure-field Paste is an explicit
system paste action. Settings shares card/row layout and sizes to its content.

The editor is a 540 × 600-point sheet capped to its presenting window, with a
128-point label column and 12-point gaps. General, Display, Devices & audio,
Terminal and Security tabs appear as applicable. Header/tabs/actions stay fixed;
one body scroll view handles short windows and long folder lists. Tab state starts
on General and falls back there if a tab becomes unavailable. The Terminal tab previews its theme and font size through the local terminal renderer
using self-contained fictional sample output. All tabs share the
draft/credentials; switching tabs never reloads values. Validation appears after
leaving a required field or attempting Save; new tunnels defer field errors until
edited fields lose focus or Save is attempted. Errors appear inline once, with
marked tabs and a clickable issue-count footer that reaches the invalid field.
Tunnel navigation reveals the laid-out native card before focusing its invalid
field, including near the end of the 16-tunnel list.
Edit clears automatic text selection; New focuses Address and Quick Connect focuses
its compact address input. Quick Connect parses explicit user@host:port and SSH/RDP/VNC URLs without accepting passwords.


Session navigation uses rounded 28-point tabs with close buttons; secondary tools
use underline tabs separated by a divider. Native toolbar labels use system sizing
and glass, grouped into open/session/view actions. The window title reflects the
active connection; explicit native-window registration keeps focus/prompt routing
independent of that title. Sidebar selection remains independent for profile management.
Live tunnel cards share a centered 720-point column with 24-point side padding,
a persistent header and type-specific empty-state quick starts. Saved rules with
Start on connect off remain stopped, startable cards. Terminal/file surfaces retain
usable full width. Terminal zoom/find appear only for Terminal/Split View; status
and sidebar use the same compact uptime formatter.
Saved/live tunnel forms share the 128-point right-aligned label column, 12-point
gap and 64-point port fields. Empty listen ports display Auto. Contextual warnings
cover non-loopback remote listeners and unauthenticated SOCKS access. Sidebar
state includes active/failed sessions and uptime, and duplication preserves all
raw optional metadata while assigning a fresh credential identity. Destructive
session actions ask for confirmation when file work or tunnels are active.

The Display picker maps directly to existing stored modes. A separate Resize with
window checkbox edits `dynamicResolution`; new drafts default to false, while saved
choices are preserved. The checkbox is always editable and takes precedence over the stored display mode:
RDP sessions use effective Fit mode for presentation while resizing is enabled.
With resizing enabled, initial negotiation waits for an attached viewport and 200 ms
of settled layout, using the same even-width geometry and Retina conversion as later
resize requests. This avoids connecting at a preset and immediately changing resolution.
Background reconnects reuse the last attached viewport size and backing density when
the session tab has no mounted surface.
With resizing disabled, initial sizing honors the stored Match window mode; the editor
hides preset/custom dimensions for that mode. The stored mode returns when resizing is disabled. Full-screen
and multi-monitor resize restrictions still apply. Explicit preset selection
writes only width/height; unmatched dimensions use Custom and survive tab changes.
Startup full screen disables windowed mode/resolution controls while preserving
their values. Opening the editor never rewrites settings. Security can forget an
existing identity for the entered endpoint. Save applies settings on reconnect;
Save & Connect opens a session. Organization/notes persist without editor controls.

RDP negotiates software bitmap rendering for compatibility, then presents BGRA
frames through Metal and the latest-frame mailbox. Changing graphics negotiation
requires validating actual paint delivery, not authentication alone. Fit scales the desktop and optionally requests server resize;
100% maps one remote pixel to one Mac point; Match window waits for a laid-out viewport
and, with resizing off, fixes that initial size (200–8192) until reconnect. Delivered server dimensions
remain authoritative. Fixed modes apply only when Resize with window is off. Native NSScrollView clips
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
The owning viewport also publishes its laid-out size and window/backing changes,
so a detached-window return does not depend solely on Metal surface callbacks.

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
Resize deadlines track a specific pending submission or an unmet target awaiting
capabilities. An already matching initial desktop needs no deadline; capability and
geometry callbacks retire obsolete deadlines. Expiring an intermediate request
reevaluates the latest target before reporting failure, so returning to already
observed geometry does not produce a false fallback notice.
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
Keyboard surfaces reconcile left/right modifier snapshots and release tracked input on
responder, window/app activation, reparenting and input-disable transitions. Ordinary
US text commits retain physical scan-code pairs; other committed text keeps Unicode
pairs. Caps Lock uses ordered RDP Synchronize events. See the
[keyboard input contract](rdp-keyboard.md) for event routing, evidence and layout limits.
The bounded native event queue coalesces consecutive pure pointer motion while
preserving key/button/wheel ordering. During FreeRDP reactivation/input suspension,
keyboard/pointer/toggle events remain queued rather than entering APIs that silently
skip them; clipboard ownership and control events continue draining. Queue overload stops the session with an
explicit reconnect error rather than dropping input or clipboard deactivation.
Draining stops after cancellation; no pending resize is submitted after that check.
The native clipboard adapter negotiates [MS-RDPECLIP](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeclip/cbc851d3-4e68-45f4-9292-26872a9209f2) file streaming, relative file
lists, locks and large-file ranges. Finder file URLs retain their security scopes;
regular files and folders are traversed/read on the RDP worker with no-follow
component opens, bounded entries/ranges and source identity/metadata checks.
Locked local snapshots survive clipboard replacement until unlock (at most eight).
Clipboard transfer is separate from folder redirection; source data must remain
quiescent and transfers use copy semantics. Last-write timestamps accompany file
descriptors and are restored after staging (directories last).

Remote files stream in 256 KiB requests with at most eight ranges in flight to
private temporary trees (700/600), with an 8 GiB / 20,000-entry budget
and a monotonic 30-second deadline for each outstanding response. A process-wide
reservation follows owning staging storage through completed batches and their
60-second cleanup grace period; disconnect does not release retained batch quota.
Legacy immediate consumers retain storage until disconnect. Public materialized
batches borrow URLs and never delete caller-owned roots. Stream IDs retain each
range's offset and length; reordered responses use positional writes and short
responses request only their missing suffix. Progress reports received bytes.
Descriptor paths, collisions and file/directory conflicts are validated before
creation; links, absolute/traversal paths and partial batches are rejected. Finder
gets delayed file items after descriptors are validated. Copy does not send SIZE or
RANGE requests or create the descendant tree. File-URL demand sets a thread-safe
batch request, consumed once by the RDP worker's tick; only then does staging begin.
Standard file URLs are supplied only after the entire batch completes. The main-actor
pasteboard bridge preserves a newer local copy and suppresses remote-file echoes.
One AppKit file-URL data provider retains each batch independently of the session.
It maps item identities to URLs without retaining items (which retain their provider).
AppKit's ownership-end callback cancels unfinished work for the whole batch.
File publication uses `prepareForNewContents(with: .currentHostOnly)` so Universal
Clipboard cannot request promised URLs for cross-device synchronization. This
applies to both delayed batches and legacy materialized file offers. The flag uses
Apple's [current-device-only contract](https://developer.apple.com/documentation/appkit/nspasteboard/contentsoptions/currenthostonly);
a file-URL read alone does not identify a user Paste action.
A concrete private pasteboard type prevents self-consumption even after focus reset
or when another session synchronizes. Availability checks never read delayed URLs.
AppKit's file-URL fulfillment contract is synchronous, with a five-minute deadline.
Background callers wait on a native condition; main-thread callbacks service a
bounded nested AppKit event loop so progress and cancellation remain responsive.
Per-item reentrancy guards prevent recursive fulfillment. Both wait paths check
pasteboard ownership throughout fulfillment, and a final check prevents publishing
into a newer local copy. The worker signals completion/cancellation
independently of UI callbacks; channel and disk work continue during fulfillment.
Selection changes/disconnect cancel partial downloads; completed clipboard files survive
disconnect while the app and pasteboard provider remain alive. After ownership
ends, cleanup waits 60 seconds for consumers already copying. App exit can leave
OS temporary files pending system cleanup; this is not persistent file storage.
Unidentified late format responses must drain before another request because that
PDU carries no request ID; stream IDs reject late file responses. A format timeout,
including one cancelled by a newer local copy, retires the channel and transport
through the existing bounded recovery policy. Unsupported remote formats preserve
local text. Detach clears the channel's unretained owner before native teardown.
Disk/codec work stays off the main actor. FreeRDP's Mac audio backend is bundled;
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
exists. Anonymous TLS and unimplemented proprietary authentication are refused. Classic VNC
has no certificate identity or transport encryption; the editor explains this.
WireGuard uses the common token-authenticated socket handshake before RFB bytes,
with original host identity, independent destination leases, fail-closed tunnel
startup/exit and app-shutdown worker draining.

Standard VNC reuses existing profile display/full-screen fields and exposes
fit/actual-size and single-display startup full screen. The optional
`SavedConnection.vncRemoteIsMac` metadata opts into the Apple-specific mode;
missing values remain false and existing entity/property identities are preserved.
Both modes treat received server dimensions as authoritative.

`VNCAppleSession` implements the Apple RSA-SRP authentication and encrypted record
layer on the existing VNC worker, through raw transport callbacks. It uses the
bundled OpenSSL primitives, a validated 4096-bit SRP group and SHA-512 with bounded
account-specific PBKDF2 work. RSA key approval precedes the encrypted identity
exchange; mutual SRP proof and record integrity must succeed, with no downgrade to
classic VNC. Apple RSA identities have a separate endpoint suffix from TLS pins.
No system private framework is linked and no unrelated adapter code is copied.

When ServerInit advertises Apple's session-selection phase, the worker submits
version-2 virtual-session selection with the account username/password encrypted
in separate fixed 64-byte AES-ECB fields under the mutually verified SRP key.
The handoff precedes record-layer activation, is sent once, and requires explicit
server acceptance. Unsupported capabilities, malformed replies and refusal stop
the attempt; refusal does not invalidate credentials that already passed SRP.
Credentials are never typed into a screen. The handoff rejects embedded NULs and
fields exceeding 63 UTF-8 bytes instead of truncating them. A server that does not
request this phase follows the existing connection path.

The Apple mode requests one SDR virtual display and negotiates only the supported
framebuffer/metadata encodings. Encrypted receive records preserve stream state
across fragmentation; bounded metadata is consumed before pixel rectangles.
Rekeys rotate cipher contexts without resetting record counters. Display-agent changes
renew control mode and framebuffer subscriptions. Apple keyboard/pointer events use
the native 18-byte encrypted-event envelope inside the authenticated record layer,
with the current session key, rotated together with the record ciphers. Queued
releases and clipboard typing use the same event encoder. Receive waits service
input on the owning worker; writable waits never recurse into the input pump.
Full-quality TCP delivery requests the next incremental
update after each framebuffer response, including empty responses; a renewed layout
subscription already supplies its own full refresh. It never relies solely on push
delivery after the first image. Window requests are coalesced on the protocol worker;
logical versus backing geometry remains separate for Retina. TCP framebuffer
pointer events retain framebuffer-pixel coordinates; the remote display agent
applies its Retina conversion. Server layout confirms effective size;
request submission does not establish acceptance. Session generations and prompt
cancellation remain owned by RemoteSession.

Direct Mac virtual-display connections offer Adaptive HEVC alongside full-quality
TCP. `VNCAppleMediaOffer` independently serializes binary-plist/zlib/protobuf
capabilities for one SDR, 8-bit 4:2:0 tile and validates the server's intersection.
Both Wi-Fi and wired low-latency bandwidth profiles are supplied; omitting the
wired ceiling can produce an accepted configuration with a zero transmitter maximum.
The mandatory audio offer disables audio by requesting a bitrate below its floor.
Media flags request one stream without an embedded remote cursor. The local cursor
remains visible, but the tested host still includes its remote cursor; cursor
omission is a request rather than confirmed host behavior. Confirmed display-layout changes request a fresh video picture
without waiting for desktop input.
Media configuration and fresh directional 46-byte SRTP keys travel only inside the
authenticated encrypted control connection. No private Apple framework is linked.
`VNCAppleVideo` binds the server-selected UDP video port on the TCP connection's
local interface and connects it to that authenticated TCP peer. Static libSRTP
handles AES-256-CM/HMAC-SHA1-80, rollover, replay checks and authenticated RTCP.
An independent HEVC depacketizer follows negotiated interleaving (screen protobuf
field 14) to include or omit DONL fields, bounds fragments and
reordering, and requests fresh reference pictures after loss. Public VideoToolbox
requires hardware decoding; decoded BGRA frames feed the existing latest-frame
mailbox on the VNC worker. Unsupported negotiation, port conflicts or startup decode
timeout remove the Adaptive encoding and renew full-quality TCP delivery.
The worker pumps media during TCP receive waits as well as its ordinary input loop.
Audio, HDR, a second virtual display, legacy Apple DH, direct SRP and Kerberos are
not implemented. A selected VPN keeps the existing TCP destination lease; Adaptive
UDP is disabled before negotiation and never bypasses the VPN.
VNC key events use X11 keysyms, including full Unicode scalars. Explicit clipboard
typing reads a snapshot on user action, normalizes CRLF/CR to Return, maps Tab,
rejects other controls and caps the batch at 16384 scalars. Worker-paced down/up
pairs at approximately 5 ms per character never send ClientCutText. Cancellation
cannot retract characters already delivered. Focus loss releases pressed input;
selection changes, disconnect and Ctrl+Alt+Delete cancel pending typing. Ctrl+Alt+Delete
is one queued sequence with releases in reverse order. ServerCutText is bounded
and discarded; no clipboard timer, file transfer or automatic clipboard reads
exist for VNC. VNC printable input uses AppKit’s committed characters as keysyms, preserving
Shift, Caps Lock and shifted punctuation. RDP keeps its physical printable-key
fast path. Nonprinting VNC keys and shortcuts use the existing US scan-code map
translated to keysyms; server keyboard/Unicode behavior remains an interoperability
limit.

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
Device teardown atomically marks the backend cancelled before draining its serial
queue. Queued requests complete as cancelled without mutations or delete-on-close;
an already executing filesystem operation may finish. Handles and security scopes
retire on the worker after queued completions drain.

Supported requests cover create/open/close, 64-bit-offset reads/writes, directory
pagination, basic/name/standard/all metadata, timestamps/attributes, rename,
truncate, delete-on-close and volume information. Empty query-directory replies
include the compatibility padding byte required by Windows at enumeration end;
the shared empty-response encoder also handles errors and cancellation.
Directory notifications, byte-range
locking, security-descriptor updates and arbitrary device controls return unsupported;
this is folder access, not a complete Windows filesystem emulation. Up to 16 named
exports, 1,024 handles/device and 1 MiB I/O requests bound resource use.
Each directory search retains an independent native cursor, streams one packed
record per request (as the FreeRDP drive implementation does), and obtains metadata
once for each returned entry. No full-folder snapshot, sorting or listing-count cap
is needed. Search restarts reopen their own cursor; opening through dup alone would
share offsets. Small metadata replies allocate only a small response buffer.
Search treats square brackets as literal Windows filename characters instead of
POSIX character classes, while retaining case-insensitive `*` and `?` matching.
Listing requires FILE_LIST_DIRECTORY/read access. Network round trips still bound
large-folder throughput; streaming is not a claim of comparative server speed.
Windows policy may disable device redirection independently of clipboard sharing. Writable exports directly modify the selected Mac files.

## Shared SSH and SFTP

The persistent SSH surface subclasses SwiftTerm's native view for local right-click
actions. A live UserDefaults preference selects a native context menu (default) or
automatic copy/paste. Copy uses selected text or the clicked visible output line.
The context menu uses AppKit validation for its actions; explicit Paste shares the
keyboard command and sends text to the remote cursor regardless of the clicked row
or scrollback position. In automatic mode, selected text takes precedence; otherwise
text is pasted only when clicking the connected terminal's cursor row at the live
viewport, and other rows are copied. This is a cursor-line approximation, not remote
editability detection. Disconnected/file-only sessions cannot paste.
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
disable Terminal/Split and terminal tools. The secondary tool buttons enforce
per-mode disabled states; preserve that behavior when changing the mode picker.
Reconnect checks capabilities anew.
Server navigation records only successful visits in a 32-folder Back/Forward
history. A controller-local LRU listing cache retains at most 16 folders and
4 MiB of accounted path/name/entry payload, with a 30-second lifetime measured
from the server read (cache hits do not extend it). Oversized listings remain
viewable but are not cached. Refresh bypasses and removes the old snapshot.
Remote mutation batches invalidate all snapshots before starting, including
failure/cancellation paths; reconnect/disconnect clear cache and history.
Cached metadata is only a display hint: the native operation's current-server
preflight and conflict checks remain authoritative. Independent filename filters
operate on existing listings; hidden selections cannot enter transfers, context
actions or Select All. No cache/history is persisted or shared across sessions.
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

## SSH forwarding

`SSHForwardingRule` holds optional profile metadata for local TCP, loopback SOCKS5
CONNECT and remote TCP forwarding. `SavedConnection.sshForwardingRules` is an
optional JSON blob; absent data preserves existing profiles with no rules. Draft
decoding bounds the blob to 64 KiB and rejects unreadable settings until explicitly
reset. Existing entity/property identities and credentials remain unchanged.
Rule IDs are unique, with at most 16 validated rules. The connection editor changes
saved defaults for the next connection. Each session owns a main-actor
`SSHForwardingController` with independently mutable live rules. The live editor
can save a rule to its existing profile or keep it for this session only; only the
optional tunnel blob is updated, preserving other metadata and credentials.
Storage failure prevents runtime apply; rejected enqueue restores the prior blob.
Runtime status and actual bound ports are separate from saved configuration.
Add/edit/remove are bounded commands on the original worker. Replacement closes
the old listener and flows, retains pending libssh2 arguments through EAGAIN, then
installs the new configuration. Removing the final tunnel preserves the SSH
session; adding the first tunnel needs no reconnect. Session-only changes end on
reconnect. No system proxy settings or separate SSH logins are created.

The original native SSH worker owns local sockets, libssh2 forwarding listeners
and channels. Local/SOCKS listeners bind only 127.0.0.1 or ::1; remote listeners use
an explicit numeric address. Port zero requests a dynamic port; collisions fail
without fallback. Local fixed destinations and SOCKS names are sent through
direct-tcpip for the server to resolve/connect. Remote forwarded channels connect
to the configured Mac destination, with DNS off the worker, unique-flow completion
keys and a bounded connect deadline. SOCKS parsing is incremental, validates version,
reserved fields, names and ports, and rejects unsupported methods, BIND and UDP.
The loopback proxy intentionally has no proxy authentication; no system settings
or firewall rules change. Server policy determines remote binding and forwarding
permission, independently of SSH authentication.

At most 64 accepted flows have 256 KiB queues per direction and a 16 MiB aggregate
data-queue budget, plus at most 2 MiB of stable write-retry snapshots and bounded
control bytes. libssh2's own channel windows are additional bounded storage.
Each service pass rotates through at most eight flows with 32 KiB I/O slices.
Reads pause under backpressure; only completed bytes leave queues. Pending writes
retain their arguments across EAGAIN. Each EOF direction drains independently;
EOF does not prematurely close reverse traffic. Handshake/connect and control
requests have 20-second deadlines, failed SOCKS replies five seconds, and channel
close retries ten seconds. Unrecoverable pending library state ends the transport
rather than reusing it with abandoned control packets.

Session-level channel opens and remote-listener requests retain their pending
arguments and are serialized. Lazy SFTP initialization drains pending forwarding
control requests before taking the generic channel-open state. Keepalives always request
no reply, including sessions that initially have no tunnels: libssh2's keepalive sender does not consume
replies, and uncorrelated global replies would otherwise be mistaken for remote
listener responses. Transport EOF is detected even without a shell or SFTP.

One interactive service hook pumps terminal and established forwarding work in
the idle loop, SFTP waits/chunks, recursive preflight, overwrite prompts and cleanup
waits. Polling preserves/combines library readiness and watches local flow sockets;
rule commands wake the worker through an owned socket pair. Active forwarding uses
the smaller interactive SFTP budget, including Files mode. All native handles stay
on the worker, and callbacks use session generation guards on the main actor.
Terminal and file capabilities are independent: configured forwarding-only accounts
remain connected in Tunnels. Ordinary profiles with neither service still fail.

Stop closes one rule's listener and flows; other rules, terminal and SFTP remain
usable. File cancellation affects only file work. Disconnect/transport loss/quit
close all sockets and drain native cleanup; reconnect creates fresh rules/ports.
If WireGuard is selected, forwarding rides the existing SSH destination lease and
retains original SSH trust, with no new helper or direct fallback. The server's
forwarded destinations are reached from the server, outside the Mac-to-SSH lease's
AllowedIPs restriction. SSH encrypts its transport hop; destination protocols must
provide any required protection beyond the SSH server.

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
The session status bar observes a separate VPN lease state: waiting, connecting,
ready, failed or disconnected. Ready means the helper supplied a destination lease,
not a continuous peer-health probe. Protocol failure releases the lease; VPN failure
remains visible until manual disconnect or a new attempt. The profile name comes from
live metadata; direct sessions omit the VPN indicator. Shared helper activity does not
keep a disconnected session’s VPN indicator green.
Native transport loss can release the lease before the helper-exit callback;
that session shows Disconnected rather than attributing the loss to the VPN.

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
version/build metadata. The app build script uses a locked build-number
reservation helper; every app build advances by one across marketing versions,
without a reset. Final bundle, loader, sandboxed-helper, mounted-DMG and
SHA256 checks are required; see [packaging](packaging.md) and [testing](testing.md).

## Unsupported features

SCP/WebDAV; SFTP resume/Finder download promises; SSH config/agent/jump hosts/
certificates/hardware keys, SOCKS BIND/UDP, HTTP proxy and streamlocal forwarding;
RDP Gateway/RemoteApp/microphone/other devices/
hardware video; nested folders/cloud sync/updater. [Validation](validation.md) tracks remaining interoperability/release work.

## OpenVPN session transport

The VPN library supports WireGuard and OpenVPN in the same Connect via workflow.
Existing `SavedWireGuard`, `WireGuardConfiguration` and `wireGuardID` identities are
retained for storage/migration compatibility. An optional `openVPN` flag in encoded
metadata selects the engine; absent means WireGuard. OpenVPN profile contents,
username, password and private-key passphrase live only in CredentialStore. The
SwiftData record contains the name and engine selection, never imported PEM data.

The existing certificate-signed helper embeds pinned OpenVPN 3 Core (MPL-2.0),
Asio and fmt. An independently written C++ adapter supplies an in-process datagram
socketpair as Core's TUN; Go connects it to the existing gVisor stack. No OS TUN,
Network Extension, privileged service, system route/DNS update or external protocol
executable is used. The Darwin four-byte packet-family header is confined to this
bridge. OpenVPN negotiates addresses, routes and DNS before a session listener is
published. Destinations outside negotiated routes fail closed. Pushed DNS servers
receive tunnel-only host routes; destination DNS never falls back to the Mac's
resolver. Endpoint hostname lookup necessarily uses the Mac's normal resolver.

One authenticated OpenVPN client is shared by leases for the same saved VPN profile.
Helper failure ends all leases; final release/EOF stops the client, packet pumps and
network stack. A transport reconnect requires a fresh lease/stack; Core cannot silently
change addresses underneath active protocol sockets. RDP retains its existing bounded
recovery policy. TCP and UDP TUN profiles support inline CA/cert/key, tls-auth,
tls-crypt and tls-crypt-v2, password authentication and encrypted private keys.
Import accepts a bounded ZIP, selected folder or individual configuration with
explicitly selected companion files. Certificates and keys are assembled inline in
memory; archive paths, symlinks, duplicate names, CRCs and expanded sizes are checked.
No archive extraction or bundled script execution occurs. The review changes only
the draft until Save. TAP exports receive an actionable TUN-export explanation.
Import enforces server certificate purpose and rejects scripts, plugins, unresolved
files, nested configs, proxies, TAP and interactive MFA. Legacy incoming LZO
decompression requires explicit import consent recorded in the protected profile;
Core uses asymmetric compression mode and never compresses outgoing traffic. Route exclusions
and unsupported pushed tunnel settings fail rather than silently changing policy.
Native logs are discarded; helper responses contain fixed error categories only.


## Optional experimental RDP behavior

Experimental RDP mode requests GFX with AVC420/AVC444 support using linked,
source-built OpenH264. Codec names are reported only after successful GFX surface
commands; a requested path is distinct from an observed path. If no initial desktop
frame arrives, or an opened GFX channel never completes its first frame within eight
seconds, the worker retires that native context and retries once with compatible
graphics. Manual disconnect cancels the retry. This per-client fallback does not
persist a capability cache or reset the existing bounded session-recovery policy.

A manual-reset event joins FreeRDP's wait set. Enqueue signals under the queue lock;
drain resets under the same lock before selecting events. Input retained during
suspension does not leave the event signaled. The 16 ms wait remains for periodic
clipboard/worker work but no longer adds that polling delay to newly queued input.

Release-enabled signposts record PDU receive, GFX surface decode, native snapshot,
input queue drain, texture upload and distinct visible drawable presentation.
Connection Details samples native activity ages and presentation interval percentiles.
These contain no payloads or endpoints and do not infer remote health from silence.
No remote TCP ACK or per-peer WireGuard receive telemetry is implemented.

GFX channel events use `RDPGFX_DVC_CHANNEL_NAME`, not the short `rdpgfx` addin name.
Connect initializes the GDI pipeline before installing measurement wrappers; close
retires its codecs and clears active state and saved callback pointers. Channel
name dispatch is covered by a negative-control initialization/cleanup regression.

Experimental RDP features are controlled by the off-by-default switch in Settings.
Each RDP connection snapshots it: disabled uses compatible bitmap graphics, full
frame snapshots/uploads and polling input; enabled uses GFX/H.264 negotiation with
startup fallback, immediate input wakeups and dirty-region snapshots/uploads.
Changes take effect on the next connection or reconnect; disabling immediately
hides experimental Connection Details. Baseline refresh pacing and drawable
lifecycle fixes remain active in both modes. OpenH264 remains bundled as an
optional software decoder; the server selects the actual codec.
