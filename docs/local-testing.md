# Local credentials and real-server testing

## Put your credentials here

`.local-testing/servers.json (relative to the repository root)`

Run `scripts/setup-local-testing.sh` to create the blank file without overwriting existing values. The directory must be owner-only (700); the file must be owner read/write (600). The entire directory is excluded by `.gitignore`. Keep keys and certificates there too. The file is **plain text on your Mac**, not encrypted; do not put it in a shared/synced directory or paste it into chat. App credentials use encrypted macOS Keychain when available; the development fallback uses owner-only, unencrypted files under ~/Library/Application Support/Farcast/Credentials.

Open the file in your own editor. Fill in host, port, username and password, and set `enabled` to `true` for each server you want tested. For RDP, fill `domain` if required. Keep UUID `id` values stable and unique; when adding another server, generate a fresh UUID. Protocol values are exactly `SSH` or `RDP`. Disabled entries are ignored and can remain blank. The tracked `Tests/Fixtures/servers.example.json` has no real information; do not put secrets in that example.

`expectedFingerprint` is the exact `SHA256:...` string shown by our adapter. Get it independently from a trusted administrator/server console. SSH automation refuses to authenticate without a pin. RDP automation accepts certificates validated by macOS for that host; if certificate validation fails, it requires an exact supplied pin. Leave a pin empty only for CA-valid RDP certificates. A changed identity fails instead of being silently accepted. UI connections always display the normal trust prompt, independently of this file.

The file workflow supports **password authentication**, including recognized masked password challenges through keyboard-interactive. Additional Interactive/MFA questions require the UI; the probe cancels rather than guessing answers. For private-key SSH, import the connection metadata and select the key in **Edit Connection**; keys/passphrases follow the same credential storage policy. Do not add arbitrary key paths or secrets to source files to automate those methods.

If the file is missing, `scripts/setup-local-testing.sh` recreates it from the blank example. Existing contents are preserved. If an editor replaces the file with broader permissions, rerun setup to restore 600. `.gitignore` prevents ordinary Git adds; it does not prevent `git add -f`, backups, uploads, or another program reading your files.

## Show test servers in the sidebar

Choose **File → Import Test Servers…**, or **Add → Import Test Servers…**, and select the local JSON file. Review the enabled entries, then Import. The app creates saved profiles under **Test Servers** in the left sidebar. Password storage on this Mac is optional and defaults off. Without it, the app asks for credentials when connecting.

Import does not start sessions. Existing UUIDs are skipped to preserve your edits; use Edit Connection to update them or remove the old profile before importing it again. Passwords/fingerprints from the document do not enter SwiftData or trust preferences. If credential storage fails after metadata import, the profiles remain visible and the app reports that credentials must be entered separately.

## Run redacted probes

```sh
scripts/test-live-servers.sh
```

The probe reads the protected local file in memory. Passwords are never process arguments. Output contains the one-based document entry ordinal, protocol, pass/fail/skip and a fixed capability/failure-stage description; library stderr is suppressed. It opens/authenticates SSH (sends no commands, using SFTP if a shell is unavailable) or waits for nonblack RDP desktop pixels (sends no input, clipboard disabled), then disconnects. A normal server session/audit record may be created; RDP can resume a user's existing desktop. Default timeout is 40 seconds per entry. Use dedicated test accounts/servers where possible.

To probe one explicitly authorized SSH entry and verify its SFTP directory access:

```sh
FARCAST_TEST_SERVER=1 FARCAST_TEST_SFTP=1 scripts/test-live-servers.sh
```

This reads directory metadata without printing file names, reading file contents,
transferring files or changing remote data. Add `FARCAST_TEST_CONFIGURED=1`
only when testing populated disabled entries is explicitly authorized. If an
independently supplied public SHA256 host-key fingerprint is available separately,
`FARCAST_TEST_SSH_PIN` can supply it for the selected entry without editing
the protected file. This override requires `FARCAST_TEST_SERVER`; the
presented key must still match exactly. Never use an unverified network key.

It returns a failure for identity, network, authentication or timeout failures. To investigate details, use the app locally; do not upload raw logs or screenshots with secrets. With all entries disabled, it reports **SKIP**, not successful real-server validation.

Synthetic tests remain separate under `.build`. They use loopback-only SSH/sample RDP services, public test-only credentials, disposable certificates and their own RDP config directory. Fixtures are not silently imported into the user's persistent library.

The protected-file probe itself is covered by `scripts/test-live-fixtures.sh`: synthetic SSH/RDP success, selected SFTP/file-only access, supplied-pin matching, missing/non-SSH selections, mismatched SSH fingerprints and malformed ID rejection. It never reads the real credentials file.

`FARCAST_TEST_CONFIGURED=1` selects populated disabled entries in memory without
changing JSON; blank entries remain skipped. Use it only with explicit authorization.
The RDP pixel check can time out on an intentionally completely black desktop.

For an explicitly authorized RDP-only full-screen probe on the current primary display:

```sh
FARCAST_TEST_RDP_FULLSCREEN=1 scripts/test-live-servers.sh
FARCAST_TEST_RDP_FULLSCREEN=1 FARCAST_TEST_RDP_RETINA=1 scripts/test-live-servers.sh
```

These require actual received pixels at the requested display dimensions, retain the
same trust checks and redaction, and send no desktop input. `FARCAST_TEST_RDP=1` selects
RDP only at the ordinary 1024 × 768 baseline. Use `FARCAST_TEST_SERVER` to select an
ordinal when needed; the configured-entry override still requires explicit authorization.

VNC profiles can be imported with `"protocol": "VNC"` and an empty username for
classic VNC authentication, then connected explicitly in the app. The redacted
live-server command currently probes SSH/RDP only; it does not establish VNC live
coverage. Use `scripts/test-vnc.sh` and the mixed WireGuard session suite for owned
synthetic VNC checks. Do not put real connection data in tracked fixtures.
