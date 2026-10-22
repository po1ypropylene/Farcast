# Bundled open-source components

Farcast's original code is licensed under the [MIT License](../LICENSE). That grant
does not replace the licenses, copyright notices or NOTICE files for the components
below. Redistributed builds must retain both Farcast's license and these notices.

| Component | Pinned release/revision | License | Upstream |
|---|---|---|---|
| OpenH264 | 2.7.0 `1bca62311e447fd9c39fc93de2c4b96cd5ce971c` | BSD-2-Clause | https://github.com/cisco/openh264 |
| FreeRDP / WinPR | 3.32.1 | Apache-2.0 | https://github.com/FreeRDP/FreeRDP |
| libssh2 | master `3209951db4e47ef902db047d12f9f464f835c27e` (1.11.2_DEV) | BSD-3-Clause | https://github.com/libssh2/libssh2 |
| OpenSSL | 3.6.5 | Apache-2.0 | https://github.com/openssl/openssl |
| SwiftTerm | 1.99.0 | MIT | https://github.com/migueldeicaza/SwiftTerm |

The adjacent files contain upstream license texts. SwiftTerm is resolved through
Swift Package Manager; the others are built from pinned source revisions by
`scripts/prepare-dependencies.sh`. Apple frameworks and the system zlib are
provided by macOS. The independently implemented VNC adapter uses the already
bundled Apache-2.0 OpenSSL for DES/TLS and system zlib; no additional VNC library
or external client is redistributed.

libssh2 deliberately uses an immutable master snapshot until a patched release is
available. It includes the packet-length bounds fix for CVE-2026-55200
([upstream commit](https://github.com/libssh2/libssh2/commit/97acf3dfda80c91c3a8c9f2372546301d4a1a7a8)).
Builds fetch the exact commit rather than following a moving branch.

FreeRDP includes Google's CPU-feature detection code; its NOTICE and license
are also included below. Test-only Paramiko is not included in the application.

## Embedded WireGuard transport

| Component | Pinned revision/version | License |
|---|---|---|
| wireguard-go | v0.0.0-20261006164505-2631ce99a06f | MIT |
| gVisor netstack | v0.0.0-20250503011706-39ed1f5ac29c | Apache-2.0 |
| Go runtime/toolchain | 1.27.1 used for validation | BSD-3-Clause |
| golang.org/x/crypto | v0.37.0 | BSD-3-Clause |
| golang.org/x/net | v0.39.0 | BSD-3-Clause |
| golang.org/x/sys | v0.32.0 | BSD-3-Clause |
| golang.org/x/time | v0.7.0 | BSD-3-Clause |
| google/btree | v1.1.2 | Apache-2.0 |

WireGuard source copyright (C) 2017–2025 WireGuard LLC. All rights reserved.
The adjacent license texts and gVisor authors list ship in the app. The compiled
module inventory/checksums are in WireGuard-build-modules.txt; go.mod/go.sum are
the authoritative build pins. The Windows-only wintun module is part of the
upstream module graph but is not compiled or bundled on macOS.

scripts/prepare-wireguard.sh builds a self-contained, arm64/macOS 27 helper with
wireguard-go's existing tun/netstack integration. Its compatible gVisor module
is deliberately pinned by wireguard-go; an arbitrary newer gVisor checkout is
not substituted.
Upstreams: https://github.com/WireGuard/wireguard-go and
https://github.com/google/gvisor. Dependency pinning/checksum verification is
not a completed vulnerability or distribution/legal review.

## OpenVPN transport

| Component | Pinned revision/version | License | Source |
|---|---|---|---|
| OpenVPN 3 Core | `1b4db00849bfb27e05c226cd13f6985527b6bb79` | MPL-2.0 (selected from upstream dual license) | https://github.com/OpenVPN/openvpn3/tree/1b4db00849bfb27e05c226cd13f6985527b6bb79 |
| Asio | 1.30.2 | BSL-1.0 | https://github.com/chriskohlhoff/asio/tree/asio-1-30-2 |
| fmt | 11.1.4 | MIT | https://github.com/fmtlib/fmt/tree/11.1.4 |

OpenVPN Core copyright OpenVPN Inc. Its unmodified MPL-covered source is available
at the exact source link above; `scripts/prepare-openvpn.sh` downloads and verifies
the corresponding archive. These source links and adjacent license texts accompany
the binary distribution. The independently written adapter in Networking/OpenVPN
is Farcast MIT source. Core and the existing OpenSSL libraries are statically linked
into the signed transport helper; no external OpenVPN executable is required.
Asio copyright Christopher M. Kohlhoff. fmt retains its copyright notice in the
adjacent license. Core’s built-in LZO decoder supports explicitly enabled incoming legacy compression;
no additional compression library is bundled.
