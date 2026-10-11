# Validation and known limits

Validation is evidence for the stated environment and scope, not a production
compatibility guarantee. Repeatable commands and fixture ownership are in
[testing](testing.md); signing requirements are in [packaging](packaging.md).

## Supplied v5 logo — 11 October 2026

- Version advances from 1.8.0 to 1.8.1 (build 1), a compatible branding correction.
  App Icon Composer layers, the sidebar template mark and the README icon use
  the supplied monitor-and-broadcast artwork. The original SVG/provenance remains
  intact. All five screenshot files are byte-for-byte unchanged.
- Layer/sidebar regeneration is reproducible. Icon Composer Default, Dark and Mono
  exports and 16/32/64/128-point previews were visually inspected, alongside the
  compiled app icon and sidebar asset loaded directly from the Release bundle.
  The README export is 512×512. These asset checks do not establish live Finder/Dock
  cache refresh, complete accessibility or the sidebar's live material appearance.
- Pinned dependency preparation, certificate-signed Release and final bundle/platform/
  dependency/signature/loader/sandboxed-helper/signing-continuity checks passed.
  Twenty-one core, 21 maintenance, 18 SSH, 82 SFTP, seven TLS RDP, eight NLA RDP
  and ten protected-probe synthetic checks passed. 26 workspace checks passed.
  Swift formatting, shell syntax,
  repository hygiene and whitespace checks passed. Icon Composer export required
  the approved environment; its sandbox failure was a tooling restriction.
- Final `Farcast-1.8.1-build-1-arm64.dmg` passed image integrity, mounted-bundle/
  signing-continuity/loader/helper verification, packaged-changelog equality and
  SHA256 verification. No commit or publication occurred.
- No real servers, protected input, saved profiles/credentials, user database or
  general clipboard were accessed. Local development signing is retained;
  Developer ID distribution and notarization remain pending.

## SSH terminal right-click — 11 October 2026

- Version advances from 1.7.4 to 1.8.0 (build 1), a compatible feature. Settings
  selects a native context menu (default) or automatic copy/paste for existing
  terminals. Copy/search uses the selection or clicked output line; automatic
  paste uses the connected terminal's cursor row at the live viewport. Files and
  images are refused even when a file clipboard also advertises a string.
- Seven production SwiftTerm/native-menu interaction checks passed with synthetic
  output, disposable preferences and a private named pasteboard: output copy and
  encoded Google search, disabled Cut/output Paste, no clipboard/input change on
  menu creation, Unicode/multiline bracketed paste, live preference changes,
  selection precedence, file-plus-text/nontext refusal, disconnect during an open
  menu, scrollback, remote mouse reporting and Shift override. The production
  Settings view was hosted in an isolated native window; a cached production-view
  image confirmed the picker, explanatory text and version row fit without clipping.
  No real browser search,
  general clipboard, saved credentials/database or real servers were accessed.
- Twenty-six workspace, 21 core, 18 SSH, 82 SFTP, ten protected-probe synthetic,
  21 maintenance and three isolated signing-continuity checks passed. Pinned
  native dependency preparation, Swift formatting, shell syntax, repository
  hygiene and whitespace checks passed. Seven TLS and eight NLA RDP checks passed
  sequentially after an initial concurrent run collided on the harness's fixed port.
  The final certificate-signed Release and mounted
  `Farcast-1.8.0-build-1-arm64.dmg` passed platform/dependency/signature/loader/
  sandboxed-helper and signing-continuity verification. DMG integrity,
  packaged-changelog equality and SHA256 verification passed. Disposable preview
  tooling/test data/logs were removed; no commit or publication occurred. Local
  development signing is retained; Developer ID distribution/notarization is pending.
- Cursor-row targeting approximates remote editability: wrapped prompts and
  full-screen programs may differ, and terminal output on the current cursor row
  cannot be distinguished from input without server cooperation. Cut is always
  disabled because a local selection cannot safely delete remote input. This is
  a native NSMenu with explicit Google search, not the full NSTextView services
  menu. Mouse-aware apps retain reporting; Shift invokes local actions. Actual
  menu clicking, live system menu appearance and complete VoiceOver remain unverified.

## Terminal background boundary — 11 October 2026

- Version advances from 1.7.3 to 1.7.4 (build 1), a compatible UI correction.
  The shared Terminal/Split background now respects every safe-area edge instead
  of extending beneath the connection sidebar. Native sidebar materials, terminal
  themes, persistent surfaces, transports and saved data are unchanged.
- Pinned dependency preparation, certificate-signed Release and final-bundle
  platform/signature/dependency/loader/sandboxed-helper checks passed. Twenty-one
  core, 18 SSH, 82 SFTP, seven TLS RDP, eight NLA RDP, ten protected-probe synthetic,
  19 workspace and 21 maintenance checks passed. Swift formatting, repository
  hygiene and whitespace checks passed.
- The final `Farcast-1.7.4-build-1-arm64.dmg` passed image integrity, mounted
  final-bundle/signing-continuity/loader/helper verification, packaged-changelog
  equality and SHA256 verification. Disposable preview tooling and test logs were
  removed; no commit or publication occurred.
- An isolated production-view preview used synthetic terminal text, in-memory
  metadata, disposable preferences and an owned empty local directory. Light/dark
  cached snapshots confirmed layout but do not capture the live sidebar glass.
  Native screenshot capture was unavailable and the UI capture tool timed out;
  live glass appearance, actual user sessions and full-screen/resizing visual
  review remain unverified. The public SwiftUI safe-area background API establishes
  the intended fill boundary; no custom sidebar material or protocol change is used.
- No real servers, protected input, saved profiles/credentials, user database or
  general clipboard were accessed. Local delivery retains the pinned development
  signing identity; Developer ID distribution and notarization remain pending.

## Keychain identity across updates — 11 October 2026

- Version advances from 1.7.2 to 1.7.3 (build 1), a compatible packaging/security
  fix. The old ad-hoc bundle identified itself by a changing code hash. Local
  script builds now use the installed Apple Development certificate for the app,
  all six libraries and the helper. The selected public fingerprint and app
  designated requirement are pinned in ignored, owner-only `.local-signing` metadata.
  Missing/expired certificates and changed requirements stop builds; explicit
  ad-hoc scratch builds cannot overwrite that pin. Credential data/ACLs are unchanged.
- Three signing integration checks passed: two different code hashes satisfy the
  same certificate-backed requirement; the first binary creates a synthetic item
  in an owned temporary Keychain; the changed binary reads it with authorization
  UI disabled. Original Keychain search lists were restored and the owned test
  Keychain was deleted. No existing saved credentials were read or exported.
- Twenty-one maintenance checks passed, including eight identity-policy cases for
  ambiguity, expired/missing pins, explicit selection, scratch opt-in, weak/hash
  requirements and changed signing channels. The certificate-signed Release passed
  platform/signature/dependency/loader and packaged sandboxed-helper verification.
  Twenty-one core, 19 workspace, 18 SSH, 82 SFTP, seven TLS RDP, eight NLA RDP
  and ten protected-probe synthetic checks passed. Final mounted 1.7.3 DMG signature,
  signing-continuity, loader/helper, changelog-equality and SHA256 checks passed.
  Shell/Python syntax, Objective-C formatting, repository hygiene and whitespace
  checks passed. Disposable signing/test data were removed; no commit or publication
  occurred. Pinned native dependencies were reused unchanged from the previous delivery.
- Existing ad-hoc items may need one final Always Allow grant per saved credential
  when adopting 1.7.3. The user's actual items/dialog were not exercised. Certificate
  renewal must preserve the recorded requirement; switching teams/channels may need
  another user-approved transition. Developer ID, hardened distribution and
  notarization remain pending. Synchronous Keychain I/O can still block the UI for
  other authorization or locked-Keychain cases; that is a separate open finding.

## Shared-transport terminal latency — 11 October 2026

- Version advances from 1.7.1 to 1.7.2 (build 1), a compatible transport reliability
  fix. Terminal/Split limits queued file data to 128 KiB uploads and 128 KiB
  download read-ahead, with ten-millisecond worker wait checks. Files retains
  4 MiB upload / 1 MiB download windows. An atomic mode hint changes budgets on
  the existing worker; one SSH login, source checks, overwrite approval, fsync
  and atomic replacement remain. Terminal write snapshots survive EAGAIN unchanged.
- A sustained echo test reproduced queueing on an owned 60 ms RTT / 512 KiB/s
  per-direction proxy. With the 1.7.1 adapter, maximum terminal delay was 3.99 s
  during upload and 3.04 s during download. The final adapter measured 0.273 s
  and 0.290 s, respectively, with no missing input and SHA256-equal round trips.
  Transfer times remained approximately 16.5 / 16.3 s on that bandwidth limit.
  Files-to-Split upload/download checks also passed, measuring 0.280 / 0.284 s
  after allowing nine seconds for pre-existing bulk data to drain. This covers
  native worker scheduling, not end-to-end typing on the user's production server.
- A separate byte-verified 64 MiB / 60 ms RTT bulk comparison measured upload
  2.60 → 2.67 s and download 1.38 → 1.37 s. Thirty-two small-file uploads measured
  6.44 → 6.47 s. These results establish no bulk-upload speed improvement; local
  scheduling and fixture overhead can vary. The 20 ms upload pipeline check passed
  (32 KiB 1.23 MiB/s versus 4 MiB 45.24 MiB/s). Terminal/Split may reduce maximum
  transfer speed on high-RTT links to keep keyboard input responsive; Files uses
  the larger pipeline. Existing TCP bytes cannot be reordered when changing modes.
- Twenty-one core, 13 maintenance, 18 SSH and 82 SFTP checks passed, including
  cancellation, same-session reuse, conflicts and recursive source-change checks.
  Nineteen workspace, seven TLS RDP, eight NLA RDP and ten protected-probe synthetic
  checks also passed. Pinned native dependencies were rebuilt at unchanged revisions.
  Final Release and mounted 1.7.2 DMG bundle/platform/signature/loader/sandboxed-helper
  verification passed, as did SHA256 and packaged-changelog equality. Formatting,
  shell/Python syntax, repository hygiene and whitespace checks passed. Local
  development signing remains ad-hoc and unnotarized; no commit or publication occurred.
- No real-server files, private configuration, saved data, credentials or clipboard
  contents were accessed. Production upload bottlenecks (network, server and cipher
  costs), loss/jitter and full terminal/UI backpressure remain unverified. No new
  authenticated sessions or relaxed file-safety policies were introduced.

## Compact Mac controls and SFTP performance — 11 October 2026

- Version advances from 1.7.0 to 1.7.1 (build 1), a compatible UI/performance fix.
  Buttons, forms, lists and segmented controls use regular Mac sizing/body fonts;
  icons are 24 points, session tabs 28 points with 22-point close controls. Toolbar
  icons use native automatic styling. Touch/iPad targets are removed from current
  agent/UI guidance. Remote terminal font preferences and user data are unchanged.
- SFTP uses file-sized buffers within 4 MiB upload / 1 MiB download maxima. Upload
  refill compaction waits for a quarter-window of acknowledgements, keeping identical
  unacknowledged bytes on EAGAIN. New destinations use exclusive create first;
  collisions still require regular-file checking and explicit overwrite approval.
  Remote preflight reuses complete READDIR metadata, with LSTAT fallback. Source
  rechecks, fsync, atomic staging/rename, single-session ownership and workers remain.
- The larger read-ahead exposed a repeatable slow file-only cancellation failure:
  pending replies could outlast the five-second handle-close deadline. Download
  cleanup now allows a bounded ten-second drain, servicing terminal I/O while waiting.
  Three focused repeats and three AddressSanitizer repeats passed, keeping the same
  login usable. Eighty-two SFTP checks passed, including in-flight terminal echo,
  cancellation/relisting, incomplete metadata fallback and a source changed after
  listing. The 20 ms RTT pipeline comparison passed (1.23 → 47.99 MiB/s).
- Sequential synthetic before/after comparisons used the original 1.7.0 adapter,
  one password-authenticated loopback session, the same deterministic byte patterns
  and conflict-enabled callbacks. Small files range from 1–50 KiB. Every uploaded
  dataset was downloaded and SHA256-compared; no resumable transfer is implemented.

| Synthetic workload | Before | After |
| --- | ---: | ---: |
| 5,000 files, 0 ms added RTT, upload | 4.81 s | 3.81 s |
| 5,000 files, 0 ms added RTT, download | 12.92 s | 9.50 s |
| 128 files, 60 ms added RTT, upload | 34.08 s | 26.26 s |
| 128 files, 60 ms added RTT, download | 51.45 s | 44.45 s |
| 1 GiB, 60 ms added RTT, upload | 35.87 s | 37.02 s |
| 1 GiB, 60 ms added RTT, download | 67.81 s | 20.01 s |

- The 1 GiB bulk/high-RTT comparison preceded the close-drain adjustment; a subsequent
  controlled 32-file check measured 6.15/10.81 s before and 6.15/10.93 s after for
  upload/download, preserving the gain within this run's variation. The 5,000-file
  low-RTT comparison used the final cleanup code. Separate window-only measurement
  improved a 64 MiB/60 ms RTT download from 4.75 to 1.45 s; upload-refill measurement
  reduced 1 GiB upload CPU time from 3.84 to 3.01 s on that run.
- These are single-host synthetic measurements, not production-server guarantees.
  Upload bulk throughput at high RTT did not improve in the full comparison.
  Host scheduling/filesystem state can vary; the proxy adds propagation delay without
  bandwidth/loss simulation. 5,000-file high-RTT runs, Instruments and a system-client
  comparison were not performed. No ciphers, socket buffers, dependency constants,
  fsync policy or extra authenticated session pool were changed.
- Twenty-one core, 13 maintenance, 19 workspace, 18 SSH, seven TLS RDP, eight NLA RDP
  and ten protected-probe synthetic checks passed. Native previews exercised the
  production compact Home/panes and live-surface pop-out/return with in-memory data.
  Cached snapshots cannot establish live glass rendering/Metal pixels; complete
  VoiceOver and real mouse/keyboard review remain outstanding.
- Final 1.7.1 Release and mounted-DMG verification passed: macOS 27/arm64,
  six-library closure, signatures, sandbox/bookmark/network rights, pre-UI loader
  and embedded-helper startup/cleanup. The packaged changelog matched and SHA256
  passed. Configured formatting, shell syntax, documentation links, repository
  hygiene and whitespace checks passed. Developer ID/notarization remain pending.
- No real servers, private local input, user database, credentials or clipboard
  contents were read. Disposable fixture data/processes and preview outputs were
  removed. No commit or publication occurred.

## Workspace windows and transfer feedback — 11 October 2026

- Version advances from 1.6.0 to 1.7.0 (build 1) for connection pop-out windows and
  SFTP transfer-speed display. Home no longer repeats the sidebar connection list;
  its remaining content is centred. Clipboard-file feedback shares the existing
  bottom status line, and all connection toolbar icons have explicit hover help.
- Detached windows present the original RemoteSession/native surface without a
  second login. Closing a window returns the live session; Close Session disconnects.
  Stable window slots follow reconnect replacements. Focus owns one clipboard/input
  target; sheets retain that target, and the Session menu routes details to its window.
  Reused RDP surfaces reject layout from their former viewport.
- SFTP displays average speed per file from a monotonic clock and worker leaf-start
  callbacks; completion/new requests/disconnect reset it and cancellation hides it.
  Seventy-seven synthetic SFTP checks passed, including recursive speed reset and
  obsolete-progress rejection. Eighteen SSH, seven TLS RDP, eight NLA RDP, ten
  protected-probe synthetic and two keyboard/display checks passed. TLS/NLA share a
  fixture port and were verified serially after an overlapping-run listener collision.
- Twenty-one core and 13 maintenance tests passed. Pinned dependencies and the RDP
  fixture were rebuilt after the outer checkout rename invalidated absolute build/
  native-library paths. This was a cache relocation issue, not protocol evidence.
- Nineteen workspace checks passed: existing SSH sign-in/shutdown, AppKit Quit/
  last-window cleanup, pop-out reuse/reconnect/return, separate inspector ownership,
  focus retained across auxiliary windows and closing another detached session,
  production native-surface reparenting/stale layout and first-use setup presentation.
  Credentials/preferences and local files were synthetic and disposable.
- The final Release and mounted 1.7.0 DMG passed macOS 27/arm64, six-library closure,
  signatures, sandbox/bookmark/network rights, pre-UI loader and embedded-helper
  startup/cleanup checks. The DMG and SHA256 were generated and the checksum passed.
  CHANGELOG.md is included, and future agent deliveries require both a changelog and
  a new verified DMG. Ad-hoc development signing/notarization limits still apply.
- File-access setup asks the user to enable Farcast manually in Full Disk Access
  settings and then choose a local folder. It neither grants permission itself nor
  reads protected personal data to test the grant. The sandbox and Home bookmark
  workflow remain. Actual TCC granting/restart and signed-app grant persistence
  remain unverified; declining broad access still permits user-selected files where
  macOS allows them.
- Native synthetic UI snapshots confirmed the centred Home content and pop-out
  controls/status bar. Cached sheet snapshots distorted material controls; the native
  UI capture tool timed out, so first-use button appearance was not established.
  NSView snapshots do not establish Metal pixel delivery;
  protocol frame checks are separate. Actual production-server pop-out use, Finder
  paste, full VoiceOver and mouse-hover tooltip timing were not exercised.
- No real servers, protected local input, user database, credentials, Keychain or
  general clipboard contents were accessed. No commit or publication occurred.

## Farcast identity and library import — 11 October 2026

- Renamed UI/permission/menu text, Xcode project/target/source/module, core package,
  native adapter prefixes, WireGuard helper/module, scripts, docs and artifact names.
  App/Keychain/helper identifiers use `com.peterpo.farcast`, `.credentials` and
  `.wireguard`. The outer checkout/Git repository remain for the user to rename.
  Screenshot/icon PNG bytes are unchanged; README explains the former screenshot name.
- Version advances from 1.5.0 to 1.6.0 (build 1) for the rebrand and explicit migration
  feature. A user-selected existing Library imports into an empty new sandbox.
  Local credential copying requires opt-in; Keychain is never exported/copied.
  Original data stays untouched, and app-specific folder grants need reselection.
- Twenty-one core and 13 maintenance tests passed. A disposable old-module seed →
  Farcast import → disk reopen preserved profile/folder/tunnel IDs, raw metadata,
  dates/bookmarks, opted-in synthetic credentials, settings/trust/restoration and
  byte-for-byte unchanged source input. Core tests cover nonempty-destination refusal,
  credential opt-in, malformed credentials and symbolic-link refusal.
- An isolated native preview used actual workspace/import views, in-memory metadata,
  injected credentials and an owned old library. Visual/accessibility inspection
  confirmed Farcast labels and credential disclosure; the native folder picker
  imported a profile with its folder/tunnel displayed in the sidebar. Credential
  copying was off; source hashes stayed unchanged. This preview was unsandboxed.
  Actual user-container migration and persistent grants across signed Farcast
  relaunches remain unverified.
- Eighteen SSH, 75 SFTP, seven TLS RDP, eight NLA RDP, ten protected-probe synthetic
  and 13 workspace checks passed. Native clipboard (78), private pasteboard (9),
  folder-drive (55), keyboard/display and audio-backend checks passed. Race-enabled
  WireGuard, encrypted synthetic RDP, native transport identity, sandboxed helper
  lifecycle/shutdown and earlier-schema migration/reopening checks passed. The
  lifecycle harness now links the real clipboard/drive adapters it requires.
- Pinned dependency preparation, final Release and mounted-DMG verification passed:
  Farcast names/lowercase identifiers, macOS 27/arm64, six-library closure, signatures,
  sandbox/bookmark/network rights, loader and embedded-helper startup/cleanup.
  `Farcast-1.6.0-build-1-arm64.dmg` and SHA256 were generated and verified. Configured
  Swift/Objective-C formatting, shell syntax, local documentation links, repository
  hygiene and whitespace checks passed.
- No real servers, protected local input, user database/credential records, Keychain
  or general clipboard contents were read. Preview processes/data/preferences and
  test logs were removed. No commit, repository rename or publication occurred.
  Developer ID signing/notarization, broader accessibility and production-server
  interoperability remain pending as described below.

## Current cleanup, UI and workspace review — 10 October 2026

- README reduced to an introduction, app icon/screenshots, getting started,
  build commands and links. Detailed workflows/maintenance/testing were retained in
  focused docs. Dated crash/user-flow files were removed; reusable signing rules and
  unresolved findings remain in packaging, architecture and this document.
- README image references now use the five supplied screenshots in `docs/images`.
  Icon Composer exported the current Default macOS icon as a 512×512 PNG there,
  displayed at 128×128 in README. The export was visually inspected; image paths,
  PNG dimensions and the export script's syntax passed checks. Regeneration uses
  `scripts/export-icon.sh --readme`. This documentation-only update did not change
  the app icon source or runtime code; app/protocol suites were not repeated.
- Reusable native source/build, Go, Swift package, Python and RDP sample-server caches
  moved to `.dependencies`; installed native products remain in `Vendor/Native`.
  Actual project cleanup removed the old `.build` with accumulated fixture trees,
  private review apps and logs, preserving dependencies, tracked tests and local input.
- Pinned native dependencies and the sample RDP server rebuilt at their new paths.
  Release build passed macOS 27/arm64, six-library closure, signatures, pre-UI loader
  and the sandboxed embedded-helper startup/listener/cleanup probe. Xcode command-line
  package resolution uses `.dependencies/swift-packages`.
- Seventeen core tests passed. Six isolated workspace checks passed bidirectional/
  adjacent drag ordering, reconnect in-place, background selection, saved edit reload,
  credential/validation failure preservation, ad hoc restoration exclusion and stale
  action safety. Credential lookup/preferences were injected; no real credentials,
  networks or user library were used by these checks.
- Thirteen maintenance checks passed, including full `.build` deletion with dependency
  preservation, tracked/redirected target refusal, read-only/link safety, pin rollback,
  and harness cleanup after success/failure with child-process teardown and no children.
- Seven SSH and 67 SFTP checks passed: authentication/trust, byte equality, atomic
  conflicts, recursion/move safety, continued shell operation, cancellation and drop
  providers. The corrected controlled throughput fixture compares actual 32 KiB and
  4 MiB upload windows; both variants' bytes matched. At a simulated 20 ms RTT it
  measured 1.26/37.85 MiB/s (30.1×). This is synthetic, not production throughput.
- Four TLS RDP, five NLA RDP and four protected-file synthetic checks passed, including
  trust rejection, frames, cancellation, bad credentials and Unicode clipboard updates/
  clearing. Mac audio backend and synthetic keyboard/display checks passed.
- Race-enabled WireGuard Go tests, encrypted RDP accept/reject/clipboard checks,
  native identity hook, sandboxed shared-lease lifecycle and disposable SwiftData
  migration/reopening passed. These used generated keys and owned loopback peers.

- Visually reviewed actual tabs, sidebar, file panes and editor in an isolated native
  preview with in-memory SwiftData, stubbed credentials/transports and owned local
  files. A near-edge close click removed only its tab; a near-edge primary action
  saved a synthetic profile. Inspected primary glass buttons, SSH/RDP switching,
  disclosure activation in the blank middle of the row and scrolling to the final
  trust control. The editor retained one scroll area/scrollbar. No physical touchscreen
  or complete VoiceOver workflow was tested; the preview's session pane was stubbed.
- Final Release rebuild/bundle checks, configured Swift formatting, shell syntax,
  repository hygiene, local documentation links and whitespace checks passed.
  All integration run directories were removed on exit; the preview and temporary
  test logs/tooling were discarded after review.
No real-server run was performed for this review. The protected local input, user
clipboard, real remote files, saved profiles/credentials and user database were not
read or changed. No commit or publication was performed.

## Tab, destination and text refinement — 10 October 2026

- Prior touch-size tab/button experiments are superseded by the compact native Mac
  sizing described in the current 1.7.1 validation. Protocol glyphs and session help/
  accessibility labels remain.
- Sidebar and overview destinations append `via` plus the selected WireGuard name.
  Direct connections retain the host alone; missing tunnel references show an
  unavailable WireGuard connection. Tooltip/accessibility text retains full labels.
- Removed the descriptive rows below Server address and Port in the shared editor,
  applying to New, Quick Connect and Edit. Labels/placeholders, protocol defaults,
  validation and the single scrolling Form remain.
- Release build and final bundle/platform/signature/loader/sandboxed-helper checks
  passed. An isolated synthetic preview showed direct, via-profile and missing-profile
  sidebar labels, compact tabs, larger button text and the simplified SSH/RDP new
  forms. A near-lower-edge close click removed only its tab. Saved Edit uses the same
  source form; its menu action could not be completed by UI automation in this pass.
- Configured Swift formatting, repository hygiene and whitespace checks passed.
  No protocol behavior, persistence schema or credential handling changed; protocol
  suites were not repeated. No real servers/private input/user database were accessed.
  Disposable preview artifacts/logs were removed; no commit or publishing occurred.

## File-only SSH and file-pane headers — 10 October 2026

- SSH terminal-channel, PTY and shell refusal now verifies SFTP on the authenticated
  transport and selects Files. Shell EOF also retains SFTP when available. Terminal,
  Split, terminal zoom/search and the observed Find menu action disable when there
  is no shell. A native segmented control supplies per-segment disabled states;
  the SwiftUI macOS picker ignored disabled state on individual items.
- Removed the separate Choose folder action. The plain Local Mac heading opens
  the existing macOS folder picker (now using compact Mac sizing); matching header heights
  align local/server navigation dividers.
- Seven SSH and 74 SFTP checks passed, including all four fallback cases,
  rejection of both services, byte equality, asynchronous overwrite prompts and
  upload/download cancellation that keeps file-only access. Normal shell exit
  now checks the terminal-capability callback before the synthetic client disconnects.
- An isolated native preview used the actual RemoteSession, SSH adapter and file
  panes with a loopback server, injected owned local files and disposable trust
  preferences. Starting in Split switched to Files after shell refusal and loaded
  the listing. Accessibility reported Terminal/Split and terminal tools disabled;
  a Terminal click retained Files. Local Mac opened the standard folder picker,
  which was cancelled; visual inspection confirmed plain styling/aligned dividers.
- Release and final bundle/platform/signature/loader/sandboxed-helper checks,
  17 core, six workspace and 13 maintenance checks, configured formatting and
  repository hygiene passed. RDP protocol suites were not repeated for this SSH/UI
  change. No real servers, private input, Keychain, user clipboard or database were
  accessed. Physical touch/complete VoiceOver were not tested. Disposable preview
  processes/files/preferences and test logs were removed; no commit/publication occurred.

## Retained control verification

Earlier synthetic previews checked button edge clicks, disabled accessibility states,
editor scrolling and completion callbacks. Their 44-point touch proportions have
been superseded by native Mac sizing in 1.7.1. Current proportions are documented
in [UI guidelines](ui-guidelines.md); keyboard and full VoiceOver coverage remain
separate verification tasks.

## SSH sign-in retry and authorized SFTP probe — 10 October 2026

- Reproduced the original Password implementation's authentication rejection on a
  synthetic keyboard-interactive-only password server. The worker now negotiates
  advertised methods after trusted identity verification, supplies a recognized
  masked password challenge once, and keeps additional/visible prompts interactive.
  Cancellation, unsupported methods and successful none authentication are explicit.
- SSH credential rejection now marks the session for **Retry sign-in**. Reconnect
  requests fresh credentials rather than reloading the rejected saved value. Explicit
  Interactive retries retain server prompts. Stored credentials are not deleted by
  retry; replacement saving remains user-controlled.
- Eighteen SSH, 75 SFTP and nine workspace checks passed. The latter includes the
  production Workspace/RemoteSession/native adapter: wrong saved password → fresh
  credential prompt → keyboard-interactive sign-in → file-only SFTP listing. It used
  synthetic credentials and disposable preferences, without the user's database,
  Keychain or credential files. Earlier UI checks cover the shared button styling;
  this pass did not visually automate the new retry label or a real credential dialog.
- Ten protected-probe synthetic checks passed: SSH/RDP success, selected SFTP access,
  supplied-pin match/mismatch, invalid IDs, missing/non-SSH selections and file-only
  capability after shell refusal/EOF. Empty optional arguments work with macOS's
  bundled Bash. Probe output is restricted to ordinal/protocol and fixed descriptions.
- The explicitly authorized supplied SFTP account authenticated and returned a
  directory listing under Password both before and after this change, with the
  independently supplied public host key. This did not reproduce the reported -18
  rejection; a differing saved username/password remains unconfirmed because user
  profiles/credential stores were not inspected. The real probe sent no shell commands,
  read no file contents, transferred no files and changed no remote data. File-only
  capability was established on synthetic servers; the real probe did not observe
  shell refusal/EOF during its short no-input window.
- Protected JSON bytes and 700/600 directory/file permissions remained unchanged.
  Release/final bundle/platform/signature/loader/sandboxed-helper checks, 17 core,
  13 maintenance checks, formatting and repository hygiene passed. RDP/NLA suites
  were not repeated beyond the protected-probe RDP check. Test processes/directories,
  logs and temporary probe records were removed; no commit or publication occurred.

## Clean app termination — 10 October 2026

- Closing the last app window now quits. Both window close and Quit defer AppKit
  termination until session cancellation, SSH/SFTP and RDP native-worker cleanup,
  and all launched WireGuard helper exits complete. Already-closed/replaced tabs
  and helpers already stopping are included. New connections, prompts and tunnel
  leases are rejected during shutdown; saved tab restoration metadata is retained.
- Thirteen workspace checks passed, including actual AppKit window-close and Quit
  process exits with delayed transport doubles, one-time cleanup completion, late
  prompt cancellation and a production SSH/SFTP worker whose tab was already removed.
  The AppKit checks used synthetic sessions; simultaneous real SSH/RDP/WireGuard
  app termination was not exercised.
- Eighteen SSH, 75 SFTP, four TLS RDP, five NLA RDP and ten protected-probe synthetic
  checks passed. SSH/RDP clients now wait for native-worker completion before exiting.
  Sandboxed WireGuard shared-lease and app-shutdown checks passed, including actual
  helper exits, a helper already stopping and rejection of new leases after shutdown.
- Seventeen core and 13 maintenance checks passed. Maintenance used the test
  environment's Python because the system Python lacks pathlib.Path.hardlink_to.
  Release/final bundle/platform/signature/loader/sandboxed-helper checks, configured
  Swift/Objective-C formatting, shell syntax, repository hygiene and whitespace passed.
- No real servers, protected local input, user database, Keychain or clipboard were
  accessed. Disposable test processes/directories/logs were removed. No commit or
  publication occurred.

## RDP file clipboard and selected folders — 10 October 2026

- File clipboard initially advanced 1.3.0 to 1.4.0. This delivery advances 1.4.0
  to 1.5.0 (build 1) for per-connection selected-folder redirection and compatible
  clipboard improvements. Clipboard remains opt-in; drives have a separate list,
  unique names, read-only defaults and explicit folder selection. No automatic
  home/volume exports are enabled. App-scoped bookmarks persist permission, with
  user-selected read/write and bookmark rights checked in the final signed bundle.
- Clipboard streams complete batches into private temporary trees (700/600),
  preserving last-write timestamps. AppKit file-URL providers own completed files
  beyond session disconnect and fulfill without network waits. Partial transfers
  cancel on deselection/disconnect; transfers copy without source deletion.
  The limit is 8 GiB / 20,000 entries per batch. Completed files remain available
  while the app is open and the pasteboard provider owns them; cleanup waits 60
  seconds after ownership ends. App exit may leave OS temporary data pending system
  cleanup. These files are not persistent storage.
- Seventy-eight deterministic native clipboard and nine private-pasteboard checks
  passed: nesting, Unicode/binary/empty files, locked snapshots, 64-bit offsets,
  changed sources, invalid indexes/ranges, paths/links/aliases/conflicts, quotas,
  replacement, cancellation and late replies. Provider checks preserve completed
  URLs after bridge invalidation. Seven TLS and eight NLA RDP checks passed;
  actual-channel batch callbacks verify timestamp preservation and byte equality
  after disconnect, and drive peers verify writable open/write/read/close and
  denied write opens followed by read-only reads with unchanged local bytes.
- Fifty-five native drive checks passed, including 64-bit sparse reads/writes,
  truncation, name/basic/standard/all metadata, pagination, share conflicts,
  rename/delete, root/traversal/link refusal, malformed input, nonempty-directory
  deletion denial, each read-only mutation path and cancellation without pending
  deletion. The disposable server decoder was corrected to accept standard write
  count/padding completions; production FreeRDP dependencies are unchanged.
- Eighteen core tests and disposable SwiftData migration/reopening passed, preserving
  existing profile/folder/settings identities and new bookmark metadata. Unreadable
  saved metadata blocks connection until explicitly reset; unavailable/stale folder
  access fails closed. Thirteen workspace, 18 SSH, 75 SFTP, 13 maintenance and ten
  protected-probe synthetic checks passed. Race-enabled WireGuard tests, including
  encrypted synthetic RDP accept/reject/clipboard exchange, also passed. Release/final bundle/platform/signature/
  loader/sandboxed-helper checks passed. Existing dependency caches were reused.
- An isolated native preview rendered the actual editor with in-memory SwiftData,
  owned folder bookmarks, disposable preferences and credential loading disabled.
  Folder path/name, read-only toggle, replacement/removal/addition buttons and the
  reconnect explanation were visually inspected. The single scrolling form remains.
  The UNC explanation uses verbatim text and actions identify their folder to
  accessibility. Full VoiceOver, physical touch and an external-folder picker/
  persistent grant across signed app relaunches were not exercised in this pass.
- No real servers, protected local input, user database, Keychain or general clipboard
  were accessed. Actual Finder paste, Windows Explorer drive mapping and production
  Windows/xrdp policies still need user-flow verification. Directory notifications,
  byte-range locks, ACL editing and arbitrary device controls are unsupported;
  this is bounded folder access, not complete Windows filesystem emulation.
  Configured formatting, shell syntax, repository hygiene and whitespace checks
  passed. Disposable integration processes/data and preview tooling were removed;
  dependency caches and the built app remain. No commit or publication occurred.

## Retained evidence

Earlier isolated UI runs exercised the native workspace/editor, private-key/trust
prompts, single-scroller disclosure layout, file browser/actions and overwrite dialogs.
Synthetic sources cover core persistence, credential encoding/local permissions, endpoint
trust, import filtering/idempotence, prompt single-resolution/cancellation, saved display/
audio choices, and pre-feature SwiftData migration. The layered Icon Composer icon and
sidebar glyph were inspected at multiple sizes/appearances. Current DMG verification is recorded above; earlier local DMGs also
passed checksum and mounted final-bundle verification. See [branding](branding.md) and [development](development.md).

An explicitly authorized earlier UI run authenticated the two supplied SSH/RDP servers
and exercised saved/edit/relaunch flows, mixed sessions, SSH ANSI/UTF-8 output/search,
RDP Metal frames/mouse/ASCII input/Ctrl–Alt–Delete, reconnect and full screen. It used
isolated data; later session checks used the production local credential implementation
after a development Keychain stall. The protected JSON retained its hash/permissions;
disposable profiles/local credentials were removed, while Keychain absence was not
independently established. This proves those bounded flows on those servers only.
Unicode/IME keyboard and real clipboard/audio were not established by that run.

## Open findings and production checks

- **Keychain UI stalls:** certificate-backed updates now preserve identity, but
  synchronous credential operations can still block UI callers during authorization
  or Keychain unlocking. Explicit ad-hoc scratch builds retain the earlier update
  prompts. The fallback cannot help while a
  Keychain call is still waiting. Worker-based I/O, prompt/cancellation behavior and a
  stable distribution identity need separate implementation/testing. Workspace lookup
  failure now preserves the old session, but this does not resolve a blocking call.
- **RDP resizing:** the supplied server had no display-control channel, so dynamic
  resizing could not apply. Software bitmap negotiation delivered visible frames;
  verify capability reporting, resolution negotiation, Retina coordinates/cursor shapes
  and behavior on Windows/xrdp/server policies. Match-window mode fixes its initial size.
- **Input/sharing:** real text/file clipboard both directions, actual Finder paste, selected-folder drive interoperability, audible remote sound, additional
  keyboard layouts and Unicode/IME need verification. Synthetic clipboard exchange,
  keyboard events and silent local audio initialization are narrower evidence.
- **SSH/SFTP:** broad real-server algorithms/key formats, full-screen terminal programs,
  long/high-latency transfers, subsystem policies, large trees, concurrent writers,
  unusual filesystems and interruption during deletion need testing. Atomic upload
  overwrite requires OpenSSH POSIX rename; sources must remain quiescent for moves.
  Partial/completed destinations can remain after cancellation/failure.
- **Drag/file access:** provider/controller tests do not establish actual mouse/Finder
  dragging, sandbox-extension delivery, remote file promises, external-editor access,
  Trash or cross-volume behavior. Home needs explicit permission; server Open is a
  temporary local snapshot without automatic upload.
- **WireGuard:** production peers, internal/IPv6 DNS, endpoint roaming, network changes,
  long sessions and performance remain unverified. The signed-parent helper probe
  closes the sandbox-startup gap, not real peer interoperability.
- **UI/accessibility:** complete VoiceOver/keyboard-only workflows, larger text/display
  settings and actual touch hardware require review. The Mac interface uses native sizing; future iPad accessibility/touch
  behavior needs separate design and verification.
- **Release:** Developer ID/hardened-runtime signing, notarization, clean-Mac installation,
  vulnerability/legal review, third-party notices after upgrades and the app source
  license remain pending. The development credential fallback is unencrypted and disclosed.

Concurrent mixed sessions, suspend/resume, changed networks, failed DNS and repeated
reconnect/disconnect under memory/thread diagnostics also need broader coverage.
Disabled protected entries yield SKIP, never a real-server pass.
