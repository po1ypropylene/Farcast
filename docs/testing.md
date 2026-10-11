# Testing

`scripts/test-library-migration.sh` seeds a disposable database using the previous
Swift module, imports it with Farcast's module, then reopens the destination. It
checks profile/folder/tunnel IDs, raw metadata/dates/bookmarks, opted-in synthetic
credentials and allowlisted settings, with byte-for-byte unchanged source input.
Core tests cover import refusal for nonempty destinations, credential opt-in,
malformed input and symbolic links. No user library or Keychain is read.

```sh
swift test --scratch-path .build/core-tests

# Test-only Python dependency; it is not bundled in the app.
python3 -m venv .dependencies/test-venv
.dependencies/test-venv/bin/python -m pip install 'paramiko==4.0.0'
scripts/test-ssh.sh
scripts/test-sftp.sh
scripts/test-sftp-throughput.sh
scripts/test-sftp-terminal-latency.sh
scripts/test-signing-continuity.sh

# Build an isolated, loopback-only synthetic RDP server.
scripts/prepare-rdp-fixture.sh
scripts/test-rdp.sh
scripts/test-rdp-files.sh
scripts/test-rdp-drives.sh
scripts/test-rdp-nla.sh
scripts/test-rdp-audio.sh
scripts/test-rdp-keyboard.sh
scripts/test-live-fixtures.sh
python3 scripts/check-repository-hygiene.py

# Only after filling and enabling the protected local entries:
scripts/test-live-servers.sh
```

The SSH fixture never executes received shell commands. It checks password,
encrypted RSA and OpenSSH Ed25519 keys, interactive prompts, shell input, PTY
resize, rejected trust, wrong passwords, and cancellation. Reused fixture modes
cover keyboard-interactive-only passwords, password-method fallback, MFA, visible
and code-only prompts, prompt cancellation, unsupported methods and none authentication.
Workspace checks cover fresh credential prompts after rejection and explicit
Interactive retry without loading saved secrets. They also exercise the production
Workspace/RemoteSession/native adapter from a rejected saved password through a
fresh prompt to a file-only SFTP listing. Run `scripts/build.sh` first; this check
reuses its SwiftTerm module/object while all test executables/preferences are disposable.
Workspace checks also exercise actual AppKit last-window close and Quit with delayed
transport doubles, verify termination waits for every completion, and use the real
SSH/SFTP worker to check shutdown after its tab is removed. SSH/RDP integration
clients await worker cleanup; WireGuard lifecycle checks await actual helper exits,
including shared leases and an already-stopping helper, and reject leases after shutdown.
Workspace checks also move the production desktop through actual SwiftUI windows,
verify one surface/transport owner, focus routing and stale-viewport protection.
Optional screenshot output from PresentationChecks uses only synthetic content.

SFTP checks include per-file speed resets and ignored obsolete progress callbacks,
incomplete directory-metadata fallback, listing/source races, and file-only connections after channel/PTY/shell refusal or immediate shell EOF,
refusal of both services, keyboard-interactive password sign-in without a shell,
byte-verified transfers/overwrites and cancellation
that retains file access without a terminal. The RDP fixture uses
an upstream sample desktop, not the user's screen, and checks TLS trust decisions,
framebuffer delivery, and cancellation. It can also enable NLA with a synthetic
SAM file through `FARCAST_FIXTURE_NLA` and `FARCAST_FIXTURE_SAM`.
The disposable RDP fixture also echoes synthetic Unicode clipboard text through
the actual clipboard channel, including updates and clearing. It also relays file
lists/locks/ranges in both directions for nested folders, Unicode names, binary
payloads larger than one chunk and empty files. `test-rdp-files.sh` checks file
codec/access/cancellation against a deterministic channel, 64-bit sparse-file ranges,
malformed paths and quotas, and uses private named pasteboards to test publication,
feedback suppression and newer-copy preservation. A separate disposable signed sandboxed app check verified access to an owned
external file through a private pasteboard without broad filesystem entitlements.
No test reads the general pasteboard. Actual Finder paste and production-server file policies remain separate
manual interoperability checks. The audio test opens
the Mac output device and plays silence; the keyboard test uses synthetic events.
These tests never read the user's clipboard. Audible playback from a real server
still needs verification.
`test-rdp-drives.sh` verifies owned-root filesystem requests, read-only denial,
64-bit sparse offsets, metadata, pagination, rename/delete, malformed input and
link/traversal refusal. TLS/NLA peers exercise actual RDPDR drive announcements,
open/write/read/close and denied write opens followed by successful read-only
reads, checking local bytes afterward. The disposable server copy corrects its
write-completion decoder to read only the specified count/padding; production
FreeRDP libraries remain unchanged. `test-wireguard-migration.sh` also verifies
adding optional redirected-folder metadata to an existing synthetic library and
reopening it. None of these checks mounts or changes a real user's folder.
Fixture processes are stopped when their harness exits.

See [validation](validation.md) for completed checks and remaining release validation.
The terminal latency fixture sends input repeatedly during 8 MiB uploads/downloads
on one SSH login through an owned proxy with 60 ms RTT and 512 KiB/s per direction.
It requires at least sixteen echoed samples, no missing input and maximum latency
under 1.5 seconds, then verifies download SHA256 equality. Files-to-Split cases
allow nine seconds for already submitted bulk data to drain before applying the
same latency bound. An optional adapter source argument reports baseline timings
before running the current strict checks. It never executes real shell commands,
accesses private input or changes remote user files.
Real Windows/xrdp interoperability, clipboard round trips, all keyboard layouts,
long-running sessions, network recovery and accessibility with VoiceOver require
further validation before a production release. Older macOS and Intel are unsupported.


## Additional regression checks

```sh
python3 -m unittest discover -s Tests/Maintenance -v
scripts/test-workspace.sh
scripts/test-wireguard.sh
scripts/test-wireguard-lifecycle.sh
scripts/test-wireguard-migration.sh
scripts/test-wireguard-rdp.sh
```

Run RDP TLS and NLA suites sequentially: their sample server uses a fixed loopback port. WireGuard RDP and protected-probe checks use distinct fixed ports. Do not run two instances of the same RDP suite concurrently.

## Fixture retention

The signing continuity check certificate-signs two different disposable binaries,
checks that their code hashes differ but their requirements match, then creates a
synthetic item in an owned temporary Keychain. The updated binary must read it with
authorization UI disabled. Each probe restores the original Keychain search list;
the reader deletes the owned test Keychain. It never queries saved user credentials.

Keep tracked integration sources when they test a distinct behavior: authentication/trust, cancellation, byte equality, atomic overwrite, recursive move safety, sandbox inheritance, migration, input coordinates or bounded performance. They are reproducible test tools, not app seed data. Keep the blank server-document example because setup/import depends on it.

Every shell integration harness creates an owner-only unique directory under `.build/tests`, stops and waits for its child servers, and deletes the directory on success, failure or interruption. Generated keys, data, executables and logs are disposable. The RDP sample-server build is reusable infrastructure under `.dependencies/rdp-fixture`; its patch is derived from tracked sources. Logs from ordinary tests are not archived. `scripts/clean-project.py --apply` removes leftovers from killed/crashed runs along with other build outputs.

UI reviews should use an isolated app, in-memory metadata and synthetic profiles. Do not open the user's restored sessions or browse Home merely to inspect layout. Use disposable files for transfer tests. Touch-target checks inspect bounds and edge clicks; they do not establish physical touchscreen support on macOS.

## SFTP performance measurements

`scripts/benchmark-sftp.sh` runs synthetic large-file and recursive small-file
uploads/downloads on one SSH session, through an owned propagation-delay proxy.
It prints JSON timings and process CPU seconds, and compares SHA256 for downloaded
files. Each upload is verified by its subsequent download. It never reads private
server input or uses an external transfer executable.

```sh
# Defaults: 60 ms simulated RTT, 128 files of 1–50 KiB, one 64 MiB file.
scripts/benchmark-sftp.sh
# Low RTT and the larger workloads:
FARCAST_BENCH_RTT_MS=0 FARCAST_BENCH_SMALL_FILES=5000 FARCAST_BENCH_LARGE_MIB=1024 scripts/benchmark-sftp.sh
# Optional comparison with an owned snapshot of an earlier adapter (run first):
scripts/benchmark-sftp.sh /absolute/path/to/SSHClient-before.m
```

The proxy models propagation delay, not a bandwidth limit, packet loss or a production
server. Large workloads/high file counts can take minutes. The optional baseline
must be compatible with the current adapter header. Fixtures/keys/binaries/local data
are removed on exit. Keep only summarized measurements in docs/validation.md.
