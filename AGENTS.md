# Farcast agent guide

Read README.md, docs/architecture.md, docs/local-testing.md, docs/branding.md and docs/validation.md before changing the app. Read docs/packaging.md when touching packaging/signing.

## Product boundaries

- Native SwiftUI app, macOS 27+, **arm64 only**. No Intel/older-macOS compatibility work.
- SSH console and on-demand SFTP file transfer share one authenticated SSH session; RDP provides desktop access. No SCP/WebDAV, SSH agent requirement or external protocol executable.
- Authentication is in-app password, imported private key, or keyboard-interactive. No agent selection UI.
- Protocol adapters are independently written. Do not copy code or assets from unrelated projects.
- Do not spawn subagents unless the user explicitly asks for delegation.

## Code placement

App contains lifecycle/composition. Domain contains connection drafts, protocol/auth types and session state. Persistence contains SwiftData entities/import operations. Features contains SwiftUI workflows and session/workspace controllers. Shared contains Keychain/trust, prompt coordination, and test-document parsing. Protocols contains persistent terminal/desktop surfaces. Native/SSH and Native/RDP contain Objective-C adapters and their headers. Tests/Integration is separated by protocol; fixtures are not app seed data.

Xcode uses a synchronized source folder. A file under Farcast is automatically included; avoid placing test-only tools or secrets there. The standalone Package.swift builds only Domain/Persistence/Shared for core tests. Preserve SwiftData entity names and property identities during refactoring; do not reset the user's database.

## Credentials and security

- `.local-testing/servers.json` is the user's private input; directory 700/file 600, ignored by Git. Run scripts/setup-local-testing.sh to create it without overwriting existing values.
- Never cat, echo, quote, log or reproduce that file in chat, patches, screenshots, reports, terminal output or test failures. Never pass credentials in process arguments. Read it in memory only for authorized testing.
- Do not copy real host names/passwords/keys/certificates into tracked fixtures. The tracked example has blank values and disabled entries. Do not add secrets to .gitignore itself.
- Use scripts/test-live-servers.sh for redacted real-server probes. Its stdout uses ordinal server numbers only; stderr from protocol libraries is suppressed. SSH requires an independently verified SHA256 fingerprint; untrusted RDP needs a matching pin. Never enable accept-all trust to unblock a test.
- App profiles contain metadata; credentials use Keychain when available, with the user-authorized development fallback in ~/Library/Application Support/Farcast/Credentials (directory 700, files 600, atomic writes). Local files are unencrypted; disclose this in credential-saving UI. Import previews omit passwords. Import does not automatically trust fingerprints or connect. Private-key import requires user-selected file access.
- Do not read the user's clipboard, export Keychain, or alter remote files for testing. A live probe opens/authenticates a shell/desktop and disconnects, sends no shell commands or desktop input. It may create a normal server session/audit record; RDP may resume an existing user session.
- Shell/network escalation can be needed for caches, dependency builds, test listeners and launching the app. Do not misreport sandbox errors as application failures.

## Build and verification

1. scripts/prepare-dependencies.sh (pinned source; ignored .dependencies and Vendor/Native).
2. scripts/build.sh (Release, pinned Apple Development signing, hardened runtime disabled for local development; bundle verifier and loader check included). Run scripts/test-signing-continuity.sh when changing signing or credential access.
3. swift test --scratch-path .build/core-tests
4. scripts/test-ssh.sh; scripts/test-sftp.sh
5. scripts/prepare-rdp-fixture.sh; scripts/test-rdp.sh; scripts/test-rdp-nla.sh
6. scripts/test-live-fixtures.sh (protected-file probe against synthetic servers)
7. scripts/test-workspace.sh; python3 -m unittest discover -s Tests/Maintenance -v
8. python3 scripts/check-repository-hygiene.py
9. scripts/test-live-servers.sh only when enabled entries are supplied; SKIP is not a real-server pass.

For every completed logical code change, build a new DMG with `scripts/build-dmg.sh`
after the final edits and version bump. Verify the mounted final bundle and SHA256;
deliver the versioned DMG path. Intermediate edits/test builds do not each need a DMG.
Documentation/instruction-only changes do not require a new app artifact.

Use a real Developer ID identity and ENABLE_HARDENED_RUNTIME=YES for distribution; notarization remains pending. Never combine ad-hoc signing with hardened runtime: macOS library validation rejects the bundled ad-hoc dylibs before Swift starts. Do not add disable-library-validation as a workaround. Verify final bundles, not just loose library signatures.

Local deliveries must retain certificate-backed signing and the designated requirement
recorded in ignored `.local-signing/identity.json`. Do not silently switch certificates,
teams/channels or fall back to ad-hoc signing; expired/unavailable pins must stop the
build. Explicit `FARCAST_SIGNING_IDENTITY=-` is for requested scratch builds and can
cause repeated Keychain prompts. Never weaken credential ACLs or export saved secrets
to avoid approval. Renew/select certificates through the packaging workflow. Sandboxed
identity enumeration can report an empty list; check in the approved build environment
before claiming that no certificate is installed.

Run swift-format using .swift-format for owned Swift sources. Objective-C adapters use clang-format. Do not format vendored upstream code. Keep callbacks on protocol workers, UI updates on the main actor, SSH backpressure and RDP latest-frame buffering intact. Disconnect must cancel outstanding prompts and transport work; reconnections must ignore stale callbacks.

## Automatic versioning

- Automatically advance the app version for each completed logical app change, without asking for confirmation, unless the user explicitly supplies a version or asks to keep it unchanged. Apply the bump before final build/bundle verification and report the old/new versions and the reason in delivery.
- Follow [Semantic Versioning](https://semver.org/): **PATCH** for backward-compatible fixes (including reliability, security, performance and corrections to existing UI); **MINOR** for backward-compatible features or deprecation of supported functionality; **MAJOR** for incompatible changes to supported behavior, interfaces, import/export formats or persistence compatibility. Judge compatibility from the user's documented workflows and data, not internal implementation details. A refactor or compatible data migration alone is not a major change. Existing data-preservation requirements still apply.
- Use the highest applicable category when a task combines changes. Increment numerically: patch `X.Y.Z → X.Y.(Z+1)`, minor `X.Y.Z → X.(Y+1).0`, major `X.Y.Z → (X+1).0.0`. Never downgrade or reuse a released version for changed app contents.
- Edit only `Version.xcconfig`, the single source for `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Reset the build number to `1` when the marketing version advances. Increment the positive integer build number for a separately delivered rebuild of the same app version; ordinary local builds, test runs and intermediate edits do not each require a bump. Keep Settings and release artifact names derived from the built bundle.
- Bump once per logical delivery, not per file, fixup or verification attempt. Inspect any version change already made for that delivery and avoid a duplicate bump; raise its category if the final scope requires it. Dependency/build/packaging changes that affect the shipped app require at least a patch, or a higher category according to their effect. Documentation, agent instructions, tests and development-tool-only changes with no shipped-app effect do not require an app-version bump.

## Documentation and delivery

Starting with 1.7.0, maintain `CHANGELOG.md` for every delivered app version.
Add a dated version heading and concise line items describing user-visible changes,
fixes and material limitations. Update the entry as scope changes, before the final
DMG build; preserve earlier entries. Include it in the DMG alongside the app.

Keep docs/validation.md focused on reproducible coverage, current findings and unresolved limits; synthetic tests do not prove production-server compatibility. Do not append dated run diaries, pass counts, old artifact paths or superseded UI descriptions. Put release history only in CHANGELOG.md. Record material architectural decisions in docs/architecture.md. Do not include raw credentials, server identifiers, terminal contents or original crash logs. Do not modify Codex memory unless directly requested. Do not commit/publish unless requested. Farcast's own source license is still undecided; third-party notices must ship in the app.

## Brand assets

The source of truth is Farcast/AppIcon.icon (macOS-only Icon Composer document), not a legacy appiconset. scripts/update-icon-artwork.sh regenerates its original layer PNGs and the matching sidebar template glyph; scripts/export-icon.sh renders macOS 27 previews. Keep effects and appearance variants editable in Icon Composer. Do not reintroduce superseded product names into source, comments, identifiers or file names, except historical input recognition and fixture provenance for explicit migration, and the migration path in the user guide.

## UI and generated artifacts

- Use compact native macOS button/control sizes and body fonts, with Safari-like 28-point session tabs and 24-point icon actions. Keep accessibility labels, tooltips and visible keyboard focus. Do not impose iPad/touch sizing on the Mac app; revisit that only for an iPad version. See docs/ui-guidelines.md.
- `.dependencies` holds reusable source/build/package/module/test-environment caches; `Vendor/Native` holds installed native dependencies. `.build` contains only disposable outputs and can be removed in full when builds/tests are stopped.
- Integration scripts source scripts/test-support.sh to isolate each run and remove processes, data, logs, keys and binaries on exit. Keep tracked fixture sources only for distinct reproducible regressions. Do not retain one-off preview apps, generated fixture trees or dated incident reports.
- Keep README short. Put user workflows in docs/user-guide.md, maintenance/release commands in docs/development.md, test procedures in docs/testing.md and signing rules in docs/packaging.md. Keep specifications and procedures current; remove obsolete guidance and duplicate implementation details. Preserve README screenshots, captions, order and markup unless explicitly asked to change them.
