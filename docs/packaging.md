# Packaging and signing

Read this before changing bundle assembly, signing, sandbox entitlements or DMG creation.
See [development](development.md) for versioning and release commands.

## Local and distribution identities

Local script builds use a pinned Apple Development certificate with
`ENABLE_HARDENED_RUNTIME=NO`. `scripts/local-signing.py` selects the sole available
Apple Development identity initially, then records its public fingerprint and the
verified app designated requirement in ignored, owner-only `.local-signing/identity.json`.
All app libraries and the embedded helper use the same certificate. Subsequent builds
must preserve that requirement, and mounted DMGs verify it again. A missing/expired
certificate or changed requirement stops packaging instead of silently falling back.

Ad-hoc signatures identify a particular build by its code hash, which changes on
updates and invalidates earlier Keychain grants. Certificate-backed requirements
can recognise updated code. See Apple's [code identity guidance](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
Users adopting the certificate-signed build may need one final **Always Allow** approval
for existing items. Credential contents, service/account keys and access controls are
preserved; no automatic export, reset or all-apps access is used.

Install/renew the development certificate in Xcode → Settings → Accounts → Manage
Certificates. `security find-identity -v -p codesigning` lists public fingerprints.
Codex's restricted shell may report no identities; use the approved build environment
before interpreting that as a missing certificate.
When renewing, run `FARCAST_SIGNING_IDENTITY=<SHA1> scripts/build-dmg.sh`; the new
certificate must still produce the recorded app requirement. Changing signing teams
or channels requires a separately reviewed transition, not deleting the pin to bypass
verification. Keep `.local-signing` across ordinary build/cache cleanup; it contains
public identity metadata, while the private key remains in macOS Keychain.

Explicit scratch builds may use `FARCAST_SIGNING_IDENTITY=- scripts/build.sh`.
They do not replace the signing pin and can prompt again after every update.
Never combine ad-hoc signing and hardened runtime: library validation rejects the
bundled ad-hoc dylibs before Swift starts. DYLD can describe a library as missing
when the detailed reason is signature rejection. Verify the actual file and
runtime configuration before diagnosing a missing-library problem.

Distribution requires a real Developer ID identity, hardened runtime, matching
library/helper signatures and notarization. Do not add disable-library-validation
or remove App Sandbox to hide signing errors. Distribution remains pending.

## Repeatable bundle assembly

`bundle-libraries.py` copies the entire native dependency closure to
`Contents/Frameworks`, relocates load paths, and signs every copied library.
The third-party notice directory is replaced before copying, so read-only licenses
from a previous build cannot block updates or leave removed notices behind.

The packaging phase always runs and changes sealed resources. `build.sh` recreates
only the generated Release app before Xcode builds it, ensuring final app signing
runs while preserving compiler/dependency caches. Reusing a sealed app while
replacing dylibs can produce “a sealed resource is missing or invalid”.

## Selected-folder access

The parent retains user-selected read/write access and the app-scoped bookmark
entitlement in `Configuration/Farcast.entitlements`. Persistent RDP folder
exports use these bookmarks; no broad filesystem or Full Disk Access entitlement
is added. Xcode merges this file with generated sandbox/network entitlements.
Final bundle verification checks both selected-file and bookmark rights.
See Apple's [security-scoped access guidance](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access).

## Sandboxed WireGuard helper

The child must be signed with exactly App Sandbox and sandbox-inherit entitlements.
The parent needs both incoming and outgoing network rights for UDP reception and
loopback TCP listeners. Unsandboxed command-line fixtures cannot establish packaged
helper startup; use the real signed parent probe. No system VPN, TUN, route or DNS
changes are required.

## Final artifact checks

`verify-bundle.py` checks macOS 27 deployment, arm64-only slices, dependency closure,
relocated paths, signatures/teams, parent network rights and exact child entitlements.
It invokes `--verify-bundle-launch` before UI/storage initialization to exercise DYLD,
and `--verify-wireguard-helper` to start the real embedded helper with synthetic keys
and an owned loopback endpoint, verify a listener and cleanup. Neither reads
SwiftData, Keychain, saved profiles or private input.
`--verify-ssh-listener` also binds, accepts and exchanges a byte through the native
IPv4/IPv6 loopback listener code in the signed sandboxed parent. It uses disposable
sockets before UI/storage initialization and supplies no SSH credentials. Protocol
forwarding is verified separately against owned SSH fixtures.

`build-dmg.sh` stages the verified app, CHANGELOG.md and an Applications shortcut, creates a
compressed read-only image, verifies the mounted app and ejects that exact volume.
Temporary staging is cleaned on exit; failed detach preserves the staging directory
to avoid deleting a mounted volume. It emits a version/build-named DMG and SHA256
under `.build/releases`, with no commit, tag, upload or publishing operation.

Apple references: [sandbox inheritance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)
and [network permissions](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server).
