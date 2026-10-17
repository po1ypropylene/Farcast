# Development and maintenance

## Build from source

Install Xcode with the macOS SDK and Metal compiler, Git, CMake, Python 3 and Go 1.27+.
The first dependency build needs internet access. Install an Apple Development
certificate in Xcode → Settings → Accounts → Manage Certificates; subsequent builds
must retain the [pinned signing identity](packaging.md).

```sh
brew install cmake  # If needed
xcodebuild -downloadComponent MetalToolchain  # If Xcode reports it missing
scripts/prepare-dependencies.sh
scripts/build.sh
open ".build/Xcode/Build/Products/Release/Farcast.app"
```

Alternatively, prepare dependencies, open `Farcast.xcodeproj` and Run. Allow the
pinned SwiftTerm build plugin if Xcode requests approval.

## Maintenance tools

All three scripts preview their work by default. Python 3 is required; the updater
also uses Git, Go and Xcode for the selected components. Run them from any directory.

```sh
# Preview upstream releases; libssh2 follows master, others stay in the current major.
scripts/update-dependencies.py --latest
# Apply pins/checksums and rebuild. Protocol verification is still required.
scripts/update-dependencies.py --latest --apply --build
# Or update just one component to a selected stable release:
scripts/update-dependencies.py --freerdp 3.32.1 --apply --build
# Refresh the patched libssh2 master snapshot (resolved to an immutable commit):
scripts/update-dependencies.py --libssh2 master --apply --build

# Preview/remove generated builds, dependency caches, logs and synthetic test outputs.
scripts/clean-project.py
scripts/clean-project.py --apply

# Preview a permanent app-data reset; quit the app before applying it.
scripts/clean-user-data.py
scripts/clean-user-data.py --apply
```

The updater writes native commit pins, SwiftTerm's exact requirement and resolved
package lock, WireGuard's Go manifest/checksums, and the third-party version inventory.
It resolves WireGuard's dependency graph without independently upgrading gVisor.
Stable native/SwiftTerm versions are compared numerically by major, minor and patch;
SwiftTerm tags with `v`/`V` prefixes are recognized. Downgrades are rejected.
libssh2 is the exception: `--latest` and `--libssh2 master` resolve upstream master
to an exact commit, retaining unreleased security fixes instead of selecting 1.11.1.
Native builds record the preparation script hash, so changed pins or build flags
cannot silently reuse an older installed library. An existing source checkout at
a different revision is rejected; use the updater to invalidate generated caches.
Pin/manifest resolution failures restore the original tracked file contents;
downloaded caches may remain. Successfully applied pins remain if a subsequent
build fails. Old native outputs and synthetic RDP builds are invalidated when
native pins change. Inspect the diff, review upstream license/NOTICE changes and
refresh the bundled notices in `ThirdParty` as needed, then run the verification
commands in AGENTS.md before relying on new versions. The updater does not install
or upgrade Xcode, CMake, Python, Go, or test-only Paramiko.

Project cleanup removes all of `.build`, `DerivedData` and `build`, including app/compiler outputs, release DMGs, generated test data and ignored untracked logs/Python caches. It preserves `.dependencies`, `Vendor/Native`, tracked source fixtures, `.local-testing` and user Library/Keychain data. Stop builds and fixture servers before cleaning. Rebuild the app with `scripts/build.sh`; dependency downloads and installed libraries survive cleanup. Cleanup rejects tracked generated files and redirected build-directory parents, and never follows symlinks during deletion.

User-data cleanup permanently removes this account's Farcast container,
local credential fallback, preferences, cached/saved state and temporary SFTP previews.
This includes saved connections/folders, WireGuard profiles/keys, passwords/imported
private-key copies, server trust, settings and local-folder bookmarks. It deletes only
generic-password Keychain items in `com.peterpo.farcast.credentials`, without
reading/exporting credentials. Quit the app and tunnel helper, run as your own user
without sudo, and retain any exports you need first. Keychain authorization or macOS
Library protections may block deletion; failures return a nonzero status and can leave
a partial reset. Resolve the reported access issue and retry. Other apps' data,
original imported key/config files, the installed app, repository and protected test
input are preserved. No system privacy permissions are reset.

Maintenance regression checks use disposable files and mocked credential deletion:
`python3 -m unittest discover -s Tests/Maintenance -v`.

## Version and DMG for a release

**[Version.xcconfig](../Version.xcconfig)** is the single source for the marketing
version and positive integer build number. Both Debug and Release read it. The
current baseline was explicitly reset to **1.0.0 build 1**; earlier changelog history
was removed. Do not restore the old history or versions from older artifacts.

Ordinary work does **not** advance either number. Stage completed user-visible
changes, fixes and material limitations under **Unreleased** in
[CHANGELOG.md](../CHANGELOG.md). This is documentation staging, not Git staging.
Keep the notes current as the implementation changes.

Only a **separate explicit release/version request** promotes all staged changes to
a dated release section. Determine the highest applicable Semantic Versioning
category across the full staged scope: patch for compatible fixes, minor for
compatible features/deprecations, major for incompatible supported behavior or data
formats. An explicit version overrides that calculation. Set the new version in
Version.xcconfig and reset its build to 1, leaving an empty Unreleased section.
Advance only the build when explicitly requested for a numbered rebuild.

Every completed logical app code change still requires a verified DMG, using the
current version/build. Building a DMG does not promote notes or authorize a bump;
ordinary rebuilds replace the matching generated artifact. Documentation-only
changes do not require an app artifact. See [agent rules](../AGENTS.md).

To build the app and required DMG, run:

```sh
scripts/build-dmg.sh
```

The script builds and verifies the Release app, copies it into a compressed,
read-only DMG alongside an Applications shortcut and CHANGELOG.md, mounts the image to verify the
packaged app's signatures/libraries/loader, then ejects it. It writes:

```text
.build/releases/Farcast-<version>-build-<build>-arm64.dmg
.build/releases/Farcast-<version>-build-<build>-arm64.dmg.sha256
```

The filename comes from the built app's version fields. Rebuilding the same
version/build replaces those generated files after verification; earlier versions
remain. Both outputs are ignored by Git. The script does not read test credentials,
connect to servers, make commits/tags, upload files or create GitHub releases.
Upload the DMG as a GitHub release asset when ready; the SHA256 file is optional.
To check a downloaded DMG, place both files together and run
`shasum -a 256 -c <filename>.dmg.sha256` from that directory.

This workflow uses a **certificate-signed, unnotarized development build**. It does
not provide Developer ID signing or notarization; those remain a separate
production-release task. Users drag Farcast into Applications after
opening the DMG. Test the installed copy on another Apple silicon Mac before a
public release. The minimum supported system is macOS 27.

Keep the ignored `.local-signing` directory across local rebuilds. It pins the
certificate and app requirement so updates retain Keychain identity. See
[packaging](packaging.md) for certificate setup, renewal and explicit ad-hoc scratch builds.

## Dependency and output layout

| Path | Contents | Safe to remove routinely? |
| --- | --- | --- |
| `.dependencies/sources` | Pinned OpenSSL, libssh2 and FreeRDP source checkouts | Re-download required |
| `.dependencies/build` | Reusable native compilation trees | Recompile required |
| `.dependencies/go` | Go modules and build cache | Re-download/recompile required |
| `.dependencies/swift-packages` | Xcode package checkouts/artifacts | Re-download required |
| `.dependencies/test-venv` | Test-only Python environment | Reinstall Paramiko required |
| `.dependencies/rdp-fixture` | Reproducible patched sample-server source/build | Rebuild fixture required |
| `Vendor/Native` | Installed headers, libraries and WireGuard helper | Rebuild native dependencies required |
| `.build` | Disposable app, compiler, icon, release and test outputs | Yes, while builds/tests are stopped |

All generated paths above are Git-ignored. Command-line Xcode builds explicitly use `.dependencies/swift-packages`. Xcode UI builds use Xcode’s configured package cache; that default cache is outside this repository’s `.build`.

After relocating the checkout, discard `.build`, `.dependencies/build`, `.dependencies/rdp-fixture` and `Vendor/Native`, then rebuild. Native build trees/install prefixes retain absolute paths. Recreate the test venv at its new location; virtual environments are not relocatable. Preserve `.local-testing`. Source checkouts and package/module downloads can remain.

See [testing](testing.md) for repeatable checks and artifact cleanup, [packaging](packaging.md) for signing constraints, and [architecture](architecture.md) for ownership and security decisions.
