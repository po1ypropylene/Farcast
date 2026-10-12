# Validation and known limits

Use [testing](testing.md) for commands and fixture details. The coverage below
identifies reproducible checks, not a pass record for the current checkout.
Run the relevant suites after changes. Synthetic results establish only their
stated scope; disabled live entries report SKIP.

## Automated coverage

| Area | Checks | Evidence boundary |
| --- | --- | --- |
| Core and persistence | Draft validation, credential encoding/permissions, endpoint trust, imports, prompt cancellation, display geometry and resize coordination | Isolated stores and synthetic input |
| Migration | Old-module and pre-feature SwiftData stores, ID/metadata preservation, credential opt-in, reopening and unchanged source bytes | Disposable libraries; user-container grants need live testing |
| SSH/SFTP | Authentication/trust, fresh sign-in retry, file-only fallback, byte equality, overwrite/move safety, cancellation, terminal scheduling and throughput | Loopback peers and controlled proxies |
| VNC | RFB versions/security, DES challenge, TLS trust/refusal, raw/CopyRect/Hextile/Zlib/resize, Unicode key pairs, pointer, typing cancellation and malformed input | Owned synthetic peers; production interoperability is unverified |
| RDP channels | TLS/NLA, frames, clipboard text/files, folder drives, Display Control PDUs, initial monitor attributes and pointer input | Synthetic peers; channel submission does not prove Windows acceptance |
| RDP presentation | Cropped Metal uploads, inverse input mapping, letterbox/stale-frame rejection, full-screen startup/exit/re-entry and teardown | Marked frames and owned off-screen windows |
| Workspace | Tab ordering/reconnect, detached surface ownership, focus/prompt routing, terminal menus and AppKit shutdown | Synthetic sessions, private pasteboards and preferences |
| WireGuard | Encrypted loopback traffic, concurrent SSH/SFTP/RDP/VNC on one helper, independent disconnect/reconnect, DNS/route and host-key refusal, shared-helper failure/cleanup and schema migration | Generated keys and owned peers |
| Packaging/signing | Platform, library closure, signatures, loader, sandboxed helper, certificate continuity, mounted bundle and SHA256 | Local development artifact; distribution is separate |
| Maintenance | Cleanup boundaries, dependency rollback, signing policy, harness teardown and repository hygiene | Disposable files and mocked destructive operations |

## Known implementation limits

- **Keychain:** synchronous operations can block UI callers during authorization
  or unlocking. The local-file fallback cannot help while a call is waiting.
  Moving I/O off the main actor needs an explicit prompt/cancellation policy.
- **RDP display:** software bitmap negotiation supplies Metal frames. Dynamic
  resizing requires server Display Control support; actual received geometry is
  authoritative. Multi-monitor presentation requires matching monitor confirmation.
  Live multi-monitor topology updates are unsupported; hotplug/rotation requires
  reconnecting. Dimension confirmation does not confirm Windows DPI appearance.
- **RDP input and files:** physical scan codes use the US layout. Folder redirection
  omits directory notifications, byte-range locking and ACL editing. Clipboard
  batches are temporary, copy-only and limited to 8 GiB / 20,000 entries.
- **VNC:** classic password/no-auth has no desktop encryption or server identity;
  use WireGuard on untrusted networks. VeNCrypt requires supported X509 modes.
  ARD/proprietary security, anonymous TLS, file/audio/cursor channels and client
  resolution requests are unsupported. Clipboard typing depends on server Unicode
  keysym handling and cannot retract delivered input. Full screen uses one display.
- **SFTP:** atomic upload replacement requires OpenSSH POSIX rename. Moves require
  quiescent sources; metadata checks cannot detect every concurrent content change.
  Cancellation/failure can leave partial destinations or completed tree leaves.
  Local publication requires hard-link support. Resume and Finder download
  promises are unsupported; remote Open creates a snapshot without automatic upload.
- **WireGuard:** endpoint DNS refreshes on manual reconnect, not periodically.
  Missing profiles, tunnel failures and uncovered destinations fail closed.
- **Release:** local signing uses a pinned Apple Development certificate with
  hardened runtime disabled. Developer ID distribution, notarization, clean-Mac
  installation and vulnerability/legal review remain pending. Farcast's source
  license is undecided. The development credential fallback is unencrypted.

See [architecture](architecture.md) for ownership, protocol bounds and unsupported
features, and [packaging](packaging.md) for signing requirements.

## Live validation still required

- Windows/xrdp policy differences, real resize timing, DPI application appearance,
  cursor hotspots and two/three physical displays with mixed densities, portrait,
  changed primaries, mirroring and Spaces. Exercise full-screen exit/re-entry in
  attached and detached windows, restrictions and topology changes.
- Text/file clipboard in both directions, Finder paste, Windows Explorer folder
  drives, persistent selected-folder grants, audible remote sound and Unicode/IME.
- SSH algorithms/key formats, terminal programs, SFTP subsystem policies, long
  transfers, large trees, concurrent writers and unusual filesystems. Synthetic
  timing bounds do not establish production throughput or end-to-end typing latency.
- Finder dragging and sandbox-extension delivery, local Trash/cross-volume behavior,
  external-editor access, Full Disk Access setup and signed-app grant persistence.
- Production VNC servers (including supported macOS/Linux/Windows server modes),
  password policies, TLS chains, keyboard layouts, Unicode/IME, latency, resize,
  and full-screen input in attached/detached windows.
- Production WireGuard peers, IPv6-only/internal DNS, roaming, network changes,
  long sessions and performance.
- Complete keyboard/VoiceOver workflows, larger system text, short editor windows
  and long folder lists; visible Metal sharpness and native material appearance.
- Concurrent mixed sessions, suspend/resume, DNS failures and repeated
  reconnect/disconnect/quit under memory/thread diagnostics.

Use only authorized, redacted [live probes](local-testing.md). Do not infer broad
compatibility from a successful connection, channel write or synthetic renderer test.
