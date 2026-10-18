#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/prepare-openvpn.sh
command -v go >/dev/null || { echo 'Go 1.27+ is required to build the embedded WireGuard transport.' >&2; exit 1; }
mkdir -p .dependencies/go/build .dependencies/go/modules Vendor/Native/bin
export GOCACHE="$PWD/.dependencies/go/build" GOMODCACHE="$PWD/.dependencies/go/modules"
openvpn_digest="$(shasum -a 256 Vendor/Native/lib/libfarcast-openvpn.a | cut -d ' ' -f 1)"
cd Networking/WireGuard
go mod verify
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 CGO_CFLAGS='-mmacosx-version-min=27.0' CGO_LDFLAGS='-mmacosx-version-min=27.0' \
 go build -trimpath -ldflags="-s -w -linkmode=external -extldflags=-mmacosx-version-min=27.0 -X main.openVPNRevision=$openvpn_digest" -o ../../Vendor/Native/bin/FarcastWireGuard .
