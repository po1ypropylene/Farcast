# Bundled open-source components

| Component | Pinned release | License | Upstream |
|---|---|---|---|
| FreeRDP / WinPR | 3.32.1 | Apache-2.0 | https://github.com/FreeRDP/FreeRDP |
| libssh2 | 1.11.1 | BSD-3-Clause | https://github.com/libssh2/libssh2 |
| OpenSSL | 3.6.5 | Apache-2.0 | https://github.com/openssl/openssl |
| SwiftTerm | 1.99.0 | MIT | https://github.com/migueldeicaza/SwiftTerm |

The adjacent files contain upstream license texts. SwiftTerm is resolved through
Swift Package Manager; the others are built from pinned source revisions by
`scripts/prepare-dependencies.sh`. Apple frameworks and the system zlib are
provided by macOS.

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
