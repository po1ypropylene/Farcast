# Testing

Run from the repository root on macOS 27 / Apple silicon. Prepare dependencies and
build the Release app first; workspace/session suites reuse its SwiftTerm products.
Run compilation-based suites and packaging sequentially so their products stay stable.
See [AGENTS.md](../AGENTS.md) for the required delivery checks.

## Setup and suite selection

```sh
scripts/prepare-dependencies.sh
scripts/build.sh

# Test-only Python; never bundled in the app.
python3 -m venv .dependencies/test-venv
.dependencies/test-venv/bin/python -m pip install 'paramiko==4.0.0'
scripts/prepare-rdp-fixture.sh
```

| Command | Coverage |
| --- | --- |
| `swift test --scratch-path .build/core-tests` | Domain, persistence, credentials, trust, prompts, imports and display/resize geometry |
| `scripts/test-vnc.sh` | RFB 3.3/3.7/3.8, password/no-auth, VeNCrypt X509 modes/refusal, marked frames, malformed geometry/encoding, Unicode typing, Ctrl+Alt+Delete, pointer and cancellation |
| `scripts/test-ssh.sh` | Password/key/interactive authentication, trust, input, PTY resize and cancellation |
| `scripts/test-ssh-forwarding.sh` | Owned local/remote/SOCKS peers: byte equality, concurrent channels, server-only DNS, IPv6, fragmented/malformed proxy messages, partial writes/backpressure, both EOF directions, policy denial, fixed/dynamic ports, Stop/Start, file concurrency/conflicts/cancellation and worker drain |
| `scripts/test-ssh-forwarding-session.sh` | Production forwarding-only session capabilities, native view/controller, dynamic ports, reconnect, stale-event rejection and cleanup with isolated preferences |
| `scripts/test-sftp.sh` | Same-session files, file-only fallback, conflicts, recursion, moves, source races, progress and cancellation; synthetic navigation, cache expiry/eviction/invalidation, stale replies and filtering |
| `scripts/test-sftp-throughput.sh` | Byte-verified upload-window comparison under controlled latency |
| `scripts/test-sftp-terminal-latency.sh` | Terminal echo latency during shared-transport transfers and mode changes |
| `scripts/test-rdp.sh`, then `scripts/test-rdp-nla.sh` | TLS/NLA, frames, clipboard/drive channels, monitor/DPI negotiation, pointer input and ordered keyboard/toggle PDUs and suspended-input retention/resumption |
| `scripts/test-rdp-health.sh` | Idle desktop health, a deliberately blocked protocol worker, cancellation, abrupt TLS peer loss and retry classification |
| `scripts/test-rdp-reconnect.sh` | Three-attempt recovery, flapping/cancellation, stale-callback rejection, cleanup ordering and real TLS reauthentication in the same session; also run by the workspace suite |
| `scripts/test-rdp-files.sh` | Clipboard codecs, paths/quotas, sparse ranges, 50 MB pipelined byte equality, short/reordered/duplicate replies, Copy and idle offers without content requests, demand-only fulfillment/cancellation, UI event servicing, multi-item providers, ownership loss before demand, stalled-paste replacement and private-pasteboard ownership across focus/session changes |
| `scripts/test-rdp-drives.sh` | Owned-root filesystem requests, strict decoding of all four directory wire formats, Unicode pagination, independent streamed cursors above 20,000 entries, list-access checks, literal bracket searches, queued-operation cancellation before shutdown, empty/continuation searches, read-only denial, metadata, sharing, rename/delete and traversal refusal |
| `scripts/test-rdp-audio.sh`, `scripts/test-rdp-keyboard.sh` | Mac output initialization with silence; modifier snapshots, shifted physical letters, focus cleanup, Caps Lock, Unicode, native key repeat/menu routing, input transforms and late viewport layout after surface sizing |
| `scripts/test-rdp-resize.sh` | Actual Display Control PDUs, graphics reactivation, pixels, post-resize pointer input and repeated detached-window returns with Retina on/off |
| `scripts/test-rdp-display-session.sh` | Production full-screen startup, exit/re-entry, missing confirmation and worker cleanup |
| `scripts/test-display-migration.sh`, `scripts/test-wireguard-migration.sh`, `scripts/test-library-migration.sh` | Pre-feature/old-module store migration, IDs/defaults/bookmarks, opt-in credentials and reopening |
| `scripts/test-connection-ui.sh` | In-memory native connection/tunnel hosts, deferred validation, explicit URL ports, long-list field navigation, light/dark and wide-window layout; optional FARCAST_UI_REVIEW=1 and a directory pause synthetic scenes for native inspection |
| `scripts/test-workspace.sh` | Tabs/reconnect, prompts, sign-in retry, AppKit shutdown, detached surfaces, cropped Metal frames, terminal menus and controlled RDP retry/stall/cancellation callbacks |
| `scripts/test-wireguard.sh`, `scripts/test-wireguard-rdp.sh`, `scripts/test-wireguard-sessions.sh`, `scripts/test-wireguard-lifecycle.sh` | Go race checks, encrypted RDP, concurrent production SSH/SFTP/forwarding/RDP/VNC sessions sharing one helper, forwarded byte equality, endpoint identity, fail-closed routing and shared-lease lifecycle |
| `scripts/test-signing-continuity.sh` | Changed binaries retain certificate requirement and synthetic Keychain access |
| `python3 -m unittest discover -s Tests/Maintenance -v` | Cleanup, update rollback, signing rules and harness teardown |
| `scripts/test-live-fixtures.sh` | Redacted probe behavior against synthetic SSH/RDP servers |
| `python3 scripts/check-repository-hygiene.py` | Ignore rules, blank fixture, protected-file permissions and secret-file exclusion |

Use `.dependencies/test-venv/bin/python -m unittest discover -s Tests/Maintenance -v`
if system Python lacks `Path.hardlink_to`.

TLS and NLA share a fixed loopback port and must run sequentially. WireGuard RDP
and protected-probe suites have distinct fixed ports; never run two instances of
the same RDP suite concurrently.

## Fixture ownership and safety

Tracked sources in `Tests/Integration` exercise distinct regressions. The SSH
fixture imports `sftp_fixture.py`; the RDP sample-server preparation consumes the
protocol fixture headers. Keep `Tests/Fixtures/servers.example.json` because
setup and hygiene checks depend on its blank, disabled entries. Fixtures are not
app seed data.

Shell harnesses source `scripts/test-support.sh`, create owner-only unique trees
under `.build/tests`, stop/wait for child processes and remove data, keys, binaries
and logs on exit. `.dependencies/rdp-fixture` is a reusable sample-server build
patched from tracked headers; production FreeRDP libraries stay unchanged.
`scripts/clean-project.py --apply` removes abandoned runs and other build outputs.

Tests use loopback peers, generated keys/certificates, disposable stores/preferences
and owned files. SSH fixtures never execute shell commands. Clipboard checks use
private named pasteboards. VNC typing fixtures inject public synthetic text directly;
they do not read the general clipboard. Mixed-session tests use an owned encrypted
peer and check VNC frames and key events alongside SSH/SFTP/RDP helper sharing. UI review uses isolated apps and synthetic profiles;
never browse the user's Home, restored sessions or general clipboard for inspection.
Signing probes create an owned temporary Keychain, restore the search list and
remove the test Keychain; they never query saved user credentials.

## Important regression contracts

- Protocol-icon review covers SSH/RDP/VNC in selected/unselected native lists and
  compact tabs, in light/dark and Increase Contrast appearances. Set
  `FARCAST_PRESENTATION_SNAPSHOTS` to an existing output directory when running
  `scripts/test-workspace.sh`. Offscreen bitmap caching omits vibrant selection
  backgrounds and cannot establish selected-row contrast; inspect the synthetic
  window directly for that check. Complete VoiceOver navigation remains a separate
  manual check.

- Connection UI checks assert quiet validation and long-list reveal, centered tunnel
  empty/stopped states with stable header positions at 560/900/2500-point pane widths
  in light/dark hosts, all three template selections, terminal-tool visibility and
  idle Disconnect All. Forwarding-session checks verify that active tunnels require
  confirmation. Optional `FARCAST_UI_REVIEW=1` with `FARCAST_UI_REVIEW_SCENE=workspace-`
  and an output/control directory argument pauses owned workspace windows for visual
  review; creating `continue` in that directory advances to the next scene. Native
  glass/Reduce Transparency and VoiceOver still need direct visual/accessibility review.

- Authentication modes cover keyboard-interactive-only passwords, password fallback,
  MFA, visible/code prompts, cancellation, unsupported methods and none authentication.
  Workspace retry runs the production adapter from a rejected saved password through
  a fresh prompt to file-only SFTP without real credential lookup.
- Shutdown checks cover AppKit Quit/last-window close, delayed worker completion,
  already-removed tabs, shared tunnel leases and helpers already stopping.
- Clipboard checks include nested/Unicode/binary/empty files, locks, large ranges,
  timestamps, malformed paths, quotas, newer-copy preservation and completed URLs
  surviving disconnect. Drive peers check writable round trips and denied writes
  followed by successful read-only access with unchanged local bytes, after opening
  and enumerating the root. The fixture requests BothDirectory information and
  independently checks its 93-byte fixed wire length before decoding Unicode
  names. The fixture-only FreeRDP server decoder is extended for that format;
  production dependency sources/libraries remain unchanged. WireGuard RDP checks
  include clipboard files and root listing plus writable/read-only drive access.
  Drive peers then browse two subfolder levels, including a Unicode directory,
  and read/write a file in the deepest directory. Their directory opens include
  a trailing separator while search paths remain canonical. Native checks cover
  nested file metadata/create/rename/delete, empty directories, trailing separator
  aliases and retained traversal/symlink/read-only protections.
  Keep the upstream server's strict empty-directory padding check. Empty searches,
  enumeration end, invalid requests and disconnected directories must include
  the zero length and compatibility byte; file-read errors retain a four-byte
  zero length. A permissive decoder can hide Explorer failures after enumeration.
- Display peers decode initial monitor blocks/DPI and pointer events. TLS/NLA peers
  omit Monitor Layout confirmation; submission alone does not prove Windows acceptance.
  Resize peers delay DVC startup until activation and check storms, restrictions,
  ignored/missing channels, Retina conversion and graphics reactivation.
- Display presentation checks use marked pixels and owned off-screen windows for
  crop/input mapping, letterbox refusal, stale-frame retirement and teardown. Session
  checks pin generated certificates and inject display snapshots for repeated
  exit/re-entry, windowed startup, unsafe re-entry refusal and pending-startup cleanup.
- Migration checks seed disposable old-module/pre-feature stores, preserve IDs,
  raw metadata/dates/bookmarks, defaults and opted-in credentials, reopen the result
  and compare source bytes. Core tests cover nonempty destinations, malformed input
  and symlink refusal.

## Performance tools

The latency fixture sends repeated input during 8 MiB uploads/downloads through a
60 ms RTT / 512 KiB/s per-direction proxy. It requires at least 16 echoes, no missing
input, maximum latency below 1.5 seconds and SHA256 equality. Files-to-Split cases
allow nine seconds for queued bulk data to drain. An optional adapter-source argument
measures an owned baseline before strict current checks.

`benchmark-sftp.sh` reports JSON timings/CPU time for recursive small files and a
large file on one SSH login. Every upload is verified by a downloaded SHA256.

```sh
# Defaults: 60 ms simulated RTT, 128 files of 1–50 KiB and one 64 MiB file.
scripts/benchmark-sftp.sh
FARCAST_BENCH_RTT_MS=0 FARCAST_BENCH_SMALL_FILES=5000 FARCAST_BENCH_LARGE_MIB=1024 scripts/benchmark-sftp.sh
# Optional baseline compatible with the current adapter header:
scripts/benchmark-sftp.sh /absolute/path/to/SSHClient-before.m
```

The benchmark proxy models propagation delay, not bandwidth/loss or a production
server. Keep comparisons scoped to their workloads; discard generated logs after review.

## Real servers and manual validation

`scripts/test-live-servers.sh` requires authorized protected input and independently
verified pins. See [local testing](local-testing.md) for setup, redaction and probe
options. Disabled entries are SKIP, never a real-server pass.

Physical displays/Spaces, Finder interaction, audible remote sound, DPI/IME,
production peers, network recovery and full accessibility need manual validation.
The remaining limits are maintained in [validation](validation.md).

### OpenVPN

Run `scripts/test-openvpn.sh` for an owned loopback OpenVPN 2.6.14 peer with disposable
certificates and a null device over UDP and TCP, plus legacy AES-128-CBC/LZO
framing. The test-only server requires Homebrew `lzo` at `/opt/homebrew/opt/lzo`;
this library is not linked into or bundled with Farcast. A test-only fixed marker in the
disposable peer confirms authenticated, decrypted synthetic TCP SYN delivery before
the null device discards it. Certificate-identity rejection and startup cancellation
are checked separately. The fixture does not change system interfaces/routes
or use private input. The server source is checksum-pinned and cached separately;
it is never bundled with the app. Core tests cover safe import, credential coding
and legacy WireGuard metadata, bounded stored/deflated ZIP parsing, folder symlink
rejection, explicit companion selection, TAP refusal and compression consent. Run `scripts/test-wireguard.sh`,
`scripts/test-wireguard-sessions.sh` and `scripts/test-workspace.sh` after transport
changes. Live OpenVPN interoperability and production throughput remain unverified.

### VPN and Settings UI

Run `scripts/test-vpn-ui.sh` after building the app. It uses in-memory metadata,
injected synthetic credential storage and owned native windows to check initial
selection, dirty state, Cancel/Revert/Save, secure-field controls, inline errors,
OpenVPN summaries, missing/included companion review, TAP guidance and Settings
grouping in light/dark appearance. An optional
output directory receives synthetic view captures. It never reads the user’s
clipboard, credentials or profile library. Full VoiceOver workflows and Finder
configuration-file drops still require manual verification.

### Sidebar schema compatibility

Run `scripts/test-sidebar-migration.sh` to migrate an owned database written with
pre-sidebar folder/profile fields. It retains entity and profile identity, defaults
old folders to expanded roots, then verifies collapse persistence after renaming.
Core tests also cover nested folder metadata and retained legacy favorite metadata.
