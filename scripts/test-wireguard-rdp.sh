#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh wireguard-rdp
mkdir -p "$fixture_root"
fixture_server="${FARCAST_RDP_FIXTURE:-.dependencies/rdp-fixture/build/server/Sample/sfreerdp-server}"
[[ -x "$fixture_server" ]] || scripts/prepare-rdp-fixture.sh
Vendor/Native/bin/openssl req -config /dev/null -x509 -newkey rsa:2048 -nodes -keyout "$fixture_root/key.pem" -out "$fixture_root/cert.pem" -days 1 -subj /CN=localhost > "$fixture_root/cert.log" 2>&1
fixture_server="$(cd "$(dirname "$fixture_server")" && pwd)/$(basename "$fixture_server")"
export FARCAST_RDP_CONFIG="$fixture_root/config"
fixture_port=33989
( cd "$(dirname "$fixture_server")"; exec "$fixture_server" --port="$fixture_port" --cert="$fixture_root/cert.pem" --key="$fixture_root/key.pem" ) > "$fixture_root/server.log" 2>&1 &
fixture_pid=$!
fixture_pids+=("$!")
sleep 0.5
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Farcast/Native/RDP -I Vendor/Native/include -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -framework Security -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto "${rdp_sources[@]}" Tests/Integration/RDP/rdp_integration.m -o "$fixture_root/client"
export FARCAST_WG_RDP_CLIENT="$fixture_root/client"
export FARCAST_WG_RDP_FIXTURE_PORT="$fixture_port"
scripts/test-wireguard.sh
