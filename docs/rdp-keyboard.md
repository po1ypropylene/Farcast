# RDP keyboard review

## Symptoms and evidence

Keyboard input and clipboard redirection take different paths. Desktop key events
pass through AppKit, `RDPDesktopView`, the native input queue and FreeRDP input PDUs.
Clipboard updates use `RDPClipboardBridge` and the `cliprdr` channel. A working
mouse-driven Paste therefore does not prove that the view owns keyboard focus,
that Windows has no held modifier, or that its keyboard input path is healthy.
The reported intermittent Windows failure has not been reproduced on the user's
server. The following defects were established by source inspection and owned
AppKit/loopback regressions; their contribution to that incident remains an inference.

| Finding | Consequence | Correction |
| --- | --- | --- |
| Modifier direction was inferred by toggling the last stored state on each `flagsChanged` notification. | Duplicate snapshots could alternate press/release. Left/right overlap and missed releases could desynchronize Windows. | Reconcile actual left/right device flags from Apple's `IOLLEvent.h`, emitting only state transitions. Aggregate-only synthetic events retain known sides. |
| Printable text always used Unicode, even ordinary US letters, while physical Shift events were sent separately. | Typing capitals could leave a stream of physical Shift taps without physical letter events. This is a plausible trigger for Windows' Sticky Keys gesture. | When AppKit commits the expected US character for that physical key and Shift/Caps state, send its scan code and retain it until key-up. Other text commits retain paired UTF-16 Unicode events. No Shift release/repress is synthesized around each character. |
| The native worker drained input even when FreeRDP was inactive/suspended. Its input API returns success while silently skipping those events. | Releases during graphics reactivation, including resize, could disappear despite the app believing they were delivered. | Retain scan-code, Unicode, pointer and synchronization events in the bounded queue until active input resumes. Process clipboard/control events meanwhile so ownership cancellation is not delayed. |
| Resigning first responder released input, but retaining that responder while its window/app lost activation did not reliably do so. | A modifier released in another app could remain held remotely, making subsequent keys act like shortcuts. Clipboard and mouse input could continue working. | Observe the surface's own window losing key status and the application losing activation. Release tracked keys/buttons on those transitions, reparenting and input disable. Reconcile modifier snapshots on subsequent keyboard/pointer events to repair missed releases and recognize held modifiers on return. |
| Marked input survived input release. | Abandoned composition could affect later typing after focus/session changes. | Discard the input context's marked text and clear the local marked state on release. |
| Caps Lock toggled Windows for every notification rather than synchronizing an absolute state. | Repeated notifications and changes while unfocused could reverse its state unexpectedly. | Queue RDP Synchronize events on state changes and before input after focus return. Full-screen surfaces share the callback. |
| Only a short hard-coded list of app shortcuts escaped the desktop's key-equivalent handler. | Commands such as Quick Connect could be consumed as remote keystrokes. | Also recognize registered native menu equivalents, release forwarded Command state, and let AppKit dispatch them locally. Keep Command-C/X/V/A mapped to balanced Windows Control shortcuts. |
| Only left mouse-down explicitly reclaimed first responder. | Right-click interaction could leave keyboard focus on a local control. | All supported mouse-button presses reclaim the desktop responder. |

## Input contract

`RDPDesktopView` owns AppKit input state on the main actor. Windowed, detached and
full-screen surfaces use the same implementation. Selection, presentation teardown,
manual disconnect and recovery already call `releaseInput`; the view now additionally
handles activation and responder changes locally. Releases are idempotent. A late
key-up after release does not emit another remote release. Repeated physical
key-down events remain repeated presses with one final key-up.

AppKit interprets printable input before deciding whether a US physical scan code
is appropriate. IME/other committed text is not guessed from the physical key:
UTF-16 code units, including surrogate pairs, each have a down/up pair. Physical
navigation, function keys, Control/Option shortcuts and Windows-key combinations
retain the existing scan-code path. Mac Option continues to mean remote Alt;
local Option dead-key composition is not added by this change. Command editing
shortcuts suppress forwarded Windows keys until Command is actually released.
App and session shortcuts release held input before handing control to AppKit.

Native callbacks enqueue events under the existing lock. Only the protocol worker
calls FreeRDP. Scan codes, Unicode and toggle synchronization share that ordered
queue with pointer/button events. Only consecutive pure pointer moves coalesce;
keys remain ordering barriers. Input waits through graphics reactivation/suspension;
clipboard ownership and control work still drain. Queue overload explicitly disconnects rather than
silently dropping a release. Disconnect stops draining and recovery creates a new
client; stale-generation UI callbacks cannot deliver into its replacement.

The adapter encodes extended scan codes with the FreeRDP extended bit and uses
`KBD_FLAGS_RELEASE` for Unicode releases. The owned peer independently decodes
these events after TLS/NLA transport. FreeRDP's fast-path keyboard representation
carries press/release and extended state; repeated presses arrive as repeated
press events. No remote input is injected into real servers by these tests.

## Reproducible validation

- `scripts/test-rdp-keyboard.sh`: every left/right modifier, duplicate snapshots,
  overlapping Shifts, five Shift-letter sequences, missing-release repair, window
  and application deactivation, held-modifier restoration, input disable, Caps Lock
  synchronization, native window event routing and key repeat, Unicode fallback,
  surrogate pairs, marked-text cleanup, Mac shortcuts and viewport transforms.
- `scripts/prepare-rdp-fixture.sh`, `scripts/test-rdp.sh`,
  `scripts/test-rdp-nla.sh`: the peer decodes an ordered sequence of Shift/letter
  events, repeat presses, extended Control/navigation, Unicode code-unit pairs and
  Caps Lock synchronization. A controlled FreeRDP input suspension retains the
  complete sequence while draining clipboard ownership changes, then verifies
  decoded delivery after resumption. Missing/reordered/mismatched PDUs fail the suite.
- `scripts/test-workspace.sh` and `scripts/test-rdp-display-session.sh`: production
  session ownership, detached/full-screen surfaces, disconnect/recovery and stale
  callbacks. `scripts/test-vnc.sh` covers the shared desktop view's other adapter.

These checks do not establish how every Windows application counts accessibility
shortcuts, nor reproduce an intermittent failure in a long-lived production session.
On an authorized interactive Windows session, verify ordinary and repeated capitals
with Sticky Keys prompts enabled, overlapping left/right modifiers, app switching
while holding Control/Alt/Shift/Command, session/tab switching, sheets, pop-out and
full-screen transitions, then sustained typing. Confirm mouse/clipboard behavior
at the same time if keyboard failure returns. Real input injection is outside the
read-only live-server probe; that probe only authenticates, checks pixels and disconnects.

Physical shortcuts still assume the negotiated US layout. Non-US remote layouts,
AltGr, physical international/media keys, keyboard lock-state feedback from Windows,
full IME candidate-window behavior, sleep/wake and production long-session behavior
need separate live validation. Caps synchronization sends only the supported Caps
state; independent Num/Scroll Lock control is not implemented. Do not disable
Windows accessibility features to mask malformed client input.

## Protocol references

- [Microsoft: Keyboard and Mouse Input](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/f0ea088b-1398-43f0-af42-f4e027ab2009): input PDUs and toggle synchronization after focus changes.
- [Microsoft: Unicode Keyboard Event](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/551b9903-8fb9-4d00-b3ac-a187431efb86): UTF-16 input and release flag.
- Apple's macOS SDK `IOKit/hidsystem/IOLLEvent.h`: `NX_DEVICE*KEYMASK` constants used with AppKit event modifier snapshots.
- Pinned FreeRDP `libfreerdp/core/input.c`: scan-code/Unicode/synchronization API encoding; dependency revision is recorded in `scripts/prepare-dependencies.sh`.
