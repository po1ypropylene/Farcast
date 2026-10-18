# Farcast agent guide

Read README.md, docs/architecture.md, docs/local-testing.md, docs/branding.md and docs/validation.md before changing the app. Read docs/packaging.md when touching packaging/signing.

## Product boundaries

- Native SwiftUI app, macOS 27+, **arm64 only**. No Intel/older-macOS compatibility work.
- SSH console and on-demand SFTP file transfer share one authenticated SSH session; RDP and VNC provide desktop access. No SCP/WebDAV, SSH agent requirement or external protocol executable.
- Authentication is in-app password, imported private key, or keyboard-interactive. No agent selection UI.
- Protocol adapters are independently written. Do not copy code or assets from unrelated projects.
- Do not spawn subagents unless the user explicitly asks for delegation.

## Code placement

App contains lifecycle/composition. Domain contains connection drafts, protocol/auth types and session state. Persistence contains SwiftData entities/import operations. Features contains SwiftUI workflows and session/workspace controllers. Shared contains Keychain/trust, prompt coordination, and test-document parsing. Protocols contains persistent terminal/desktop surfaces. Native/SSH, Native/RDP and Native/VNC contain Objective-C adapters and their headers. Tests/Integration is separated by protocol; fixtures are not app seed data.

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
5. scripts/test-vnc.sh; scripts/prepare-rdp-fixture.sh; scripts/test-rdp.sh; scripts/test-rdp-nla.sh
6. scripts/test-live-fixtures.sh (protected-file probe against synthetic servers)
7. scripts/test-workspace.sh; python3 -m unittest discover -s Tests/Maintenance -v
8. python3 scripts/check-repository-hygiene.py
9. scripts/test-live-servers.sh only when enabled entries are supplied; SKIP is not a real-server pass.

Use `scripts/build.sh` and the built app for implementation, UI/flow testing and
regression checks. Do not use DMG packaging as an intermediate build or test step.
For an ordinary app-change request, finish all edits, app builds, tests and UI
verification before running `scripts/build-dmg.sh` once as the final delivery step.
DMG creation packages the existing verified Release app; it must never invoke an
app build or advance the build number. Build once, test that bundle, then package it.
Do not package separately for individual fixes or logical changes within the request.
Keep the current marketing version unless a separate release prompt authorizes advancing
it. Advance the build number for each new app build; reset it to `1` when the marketing
version advances. Verify the mounted final bundle and SHA256 and deliver the versioned DMG path.
If final packaging exposes a failure, fix it and repeat only the necessary packaging
checks. Requests specifically about DMG creation, packaging or mounted-image behavior
may require intermediate DMGs. Documentation/instruction-only changes require no app
build or DMG.

Use a real Developer ID identity and ENABLE_HARDENED_RUNTIME=YES for distribution; notarization remains pending. Never combine ad-hoc signing with hardened runtime: macOS library validation rejects the bundled ad-hoc dylibs before Swift starts. Do not add disable-library-validation as a workaround. Verify final bundles, not just loose library signatures.

Local deliveries must retain certificate-backed signing and the designated requirement
recorded in ignored `.local-signing/identity.json`. Do not silently switch certificates,
teams/channels or fall back to ad-hoc signing; expired/unavailable pins must stop the
build. Explicit `FARCAST_SIGNING_IDENTITY=-` is for requested scratch builds and can
cause repeated Keychain prompts. Never weaken credential ACLs or export saved secrets
to avoid approval. Renew/select certificates through the packaging workflow. Sandboxed
identity enumeration can report an empty list; check in the approved build environment
before claiming that no certificate is installed.

Run swift-format using .swift-format for owned Swift sources. Objective-C adapters use clang-format. Do not format vendored upstream code. Keep callbacks on protocol workers, UI updates on the main actor, SSH backpressure and RDP/VNC latest-frame buffering intact. Disconnect must cancel outstanding prompts and transport work; reconnections must ignore stale callbacks.

## Staged changes and explicit releases

- Do not automatically advance the marketing version for app changes, fixes, dependency updates, packaging work or ordinary rebuilds. Unless a new marketing version is explicitly requested, keep it unchanged and increment the build number for each new app build, including ordinary rebuilds. Documentation/instruction-only changes that produce no app build require no version or build-number change.
- Record completed changes under `## Unreleased` in `CHANGELOG.md`. Keep concise user-visible changes, fixes and material limitations current as scope changes. Staging here means changelog notes, not `git add`, a commit, a tag or publication.
- Only when the user asks in a separate prompt to release/version the staged changes: review the entire Unreleased section, determine the highest applicable Semantic Versioning category, advance the version once, and move all staged changes into a dated version section. Leave an empty Unreleased section for future work. Explain the chosen version in delivery. An explicit user-supplied version takes precedence.
- Use PATCH for backward-compatible fixes, MINOR for backward-compatible features or deprecations, and MAJOR for incompatible supported workflows, interfaces, import/export formats or persistence. Internal refactoring or a compatible migration alone is not a major change. Preserve user data in all cases.
- Edit only `Version.xcconfig`, the single source for `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Reset the build number to `1` whenever the marketing version advances; otherwise increment the build number for each new app build without requiring a separate request. Keep Settings and artifact names derived from the built bundle.
- The user explicitly reset the baseline to **1.0.0 build 1** and removed earlier release history. Do not restore old changelog entries or infer a higher version from Git history or older artifacts. Ordinary requested DMGs retain the current marketing version and use the build number of the app being packaged. Repackaging an existing app bundle alone does not advance its build number; creating a DMG does not authorize a marketing-version bump or promote staged notes.

## Documentation and delivery

Maintain `CHANGELOG.md` as the staging area described above and include it in the DMG
alongside the app. Preserve release entries created after the baseline reset unless
the user asks to change them. Documentation/instruction-only changes do not require
a new app artifact.

Keep docs/validation.md focused on reproducible coverage, current findings and unresolved limits; synthetic tests do not prove production-server compatibility. Do not append dated run diaries, pass counts, old artifact paths or superseded UI descriptions. Put release history only in CHANGELOG.md. Record material architectural decisions in docs/architecture.md. Do not include raw credentials, server identifiers, terminal contents or original crash logs. Do not modify Codex memory unless directly requested. Do not commit/publish unless requested. Farcast's own source uses the MIT License in LICENSE; that license and third-party notices must ship in the app and license text must accompany redistribution.

## Brand assets

The source of truth is Farcast/AppIcon.icon (macOS-only Icon Composer document), not a legacy appiconset. scripts/update-icon-artwork.sh regenerates its original layer PNGs and the matching sidebar template glyph; scripts/export-icon.sh renders macOS 27 previews. Keep effects and appearance variants editable in Icon Composer. Do not reintroduce superseded product names into source, comments, identifiers or file names, except historical input recognition and fixture provenance for explicit migration, and the migration path in the user guide.

## UI and generated artifacts

- Use compact native macOS button/control sizes and body fonts, with Safari-like 28-point session tabs and 24-point icon actions. Keep accessibility labels, tooltips and visible keyboard focus. Do not impose iPad/touch sizing on the Mac app; revisit that only for an iPad version. See docs/ui-guidelines.md.
- `.dependencies` holds reusable source/build/package/module/test-environment caches; `Vendor/Native` holds installed native dependencies. `.build` contains only disposable outputs and can be removed in full when builds/tests are stopped.
- Integration scripts source scripts/test-support.sh to isolate each run and remove processes, data, logs, keys and binaries on exit. Keep tracked fixture sources only for distinct reproducible regressions. Do not retain one-off preview apps, generated fixture trees or dated incident reports.
- Keep README short. Put user workflows in docs/user-guide.md, maintenance/release commands in docs/development.md, test procedures in docs/testing.md and signing rules in docs/packaging.md. Keep specifications and procedures current; remove obsolete guidance and duplicate implementation details. Preserve README screenshots, captions, order and markup unless explicitly asked to change them.
