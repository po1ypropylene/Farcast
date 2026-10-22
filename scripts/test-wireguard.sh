#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/prepare-wireguard.sh
export GOCACHE="$PWD/.dependencies/go/build" GOMODCACHE="$PWD/.dependencies/go/modules"
export FARCAST_WG_HELPER="$PWD/Vendor/Native/bin/FarcastWireGuard"
cd Networking/VPN
go test -race -count=1 -timeout=90s -v .
