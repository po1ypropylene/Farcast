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
| `scripts/test-ssh.sh` | Password/key/interactive authentication, trust, input, PTY resize and cancellation |
| `scripts/test-sftp.sh` | Same-session files, file-only fallback, conflicts, recursion, moves, source races, progress and cancellation |
| `scripts/test-sftp-throughput.sh` | Byte-verified upload-window comparison under controlled latency |
| `scripts/test-sftp-terminal-latency.sh` | Terminal echo latency during shared-transport transfers and mode changes |
| `scripts/test-rdp.sh`, then `scripts/test-rdp-nla.sh` | TLS/NLA, frames, clipboard/drive channels, monitor/DPI negotiation and pointer input |
| `scripts/test-rdp-files.sh` | Clipboard codecs, paths/quotas, sparse ranges, cancellation and private-pasteboard publication |
| `scripts/test-rdp-drives.sh` | Owned-root filesystem requests, read-only denial, metadata, sharing, rename/delete and traversal refusal |
| `scripts/test-rdp-audio.sh`, `scripts/test-rdp-keyboard.sh` | Mac output initialization with silence; synthetic keyboard/input transforms |
| `scripts/test-rdp-resize.sh` | Actual Display Control PDUs, graphics reactivation, pixels and post-resize pointer input |
| `scripts/test-rdp-display-session.sh` | Production full-screen startup, exit/re-entry, missing confirmation and worker cleanup |
| `scripts/test-display-migration.sh`, `scripts/test-wireguard-migration.sh`, `scripts/test-library-migration.sh` | Pre-feature/old-module store migration, IDs/defaults/bookmarks, opt-in credentials and reopening |
| `scripts/test-workspace.sh` | Tabs/reconnect, prompts, sign-in retry, AppKit shutdown, detached surfaces, cropped Metal frames and terminal menus |
| `scripts/test-wireguard.sh`, `scripts/test-wireguard-rdp.sh`, `scripts/test-wireguard-sessions.sh`, `scripts/test-wireguard-lifecycle.sh` | Go race checks, encrypted RDP, concurrent production SSH/SFTP/RDP sessions sharing one helper, endpoint identity, fail-closed routing and shared-lease lifecycle |
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
four protocol fixture headers. Keep `Tests/Fixtures/servers.example.json` because
setup and hygiene checks depend on its blank, disabled entries. Fixtures are not
app seed data.

Shell harnesses source `scripts/test-support.sh`, create owner-only unique trees
under `.build/tests`, stop/wait for child processes and remove data, keys, binaries
and logs on exit. `.dependencies/rdp-fixture` is a reusable sample-server build
patched from tracked headers; production FreeRDP libraries stay unchanged.
`scripts/clean-project.py --apply` removes abandoned runs and other build outputs.

Tests use loopback peers, generated keys/certificates, disposable stores/preferences
and owned files. SSH fixtures never execute shell commands. Clipboard checks use
private named pasteboards. UI review uses isolated apps and synthetic profiles;
never browse the user's Home, restored sessions or general clipboard for inspection.
Signing probes create an owned temporary Keychain, restore the search list and
remove the test Keychain; they never query saved user credentials.

## Important regression contracts

- Authentication modes cover keyboard-interactive-only passwords, password fallback,
  MFA, visible/code prompts, cancellation, unsupported methods and none authentication.
  Workspace retry runs the production adapter from a rejected saved password through
  a fresh prompt to file-only SFTP without real credential lookup.
- Shutdown checks cover AppKit Quit/last-window close, delayed worker completion,
  already-removed tabs, shared tunnel leases and helpers already stopping.
- Clipboard checks include nested/Unicode/binary/empty files, locks, large ranges,
  timestamps, malformed paths, quotas, newer-copy preservation and completed URLs
  surviving disconnect. Drive peers check writable round trips and denied writes
  followed by successful read-only access with unchanged local bytes.
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
