#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp-gfx-fallback
fixture_server="$PWD/.dependencies/rdp-fixture/build/server/Sample/sfreerdp-server"
Vendor/Native/bin/openssl req -config /dev/null -x509 -newkey rsa:2048 -nodes \
  -keyout "$fixture_root/key.pem" -out "$fixture_root/cert.pem" -days 1 -subj /CN=localhost > "$fixture_root/cert.log" 2>&1
xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 \
  -I Farcast/Native/RDP -I Vendor/Native/include -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -framework Security \
  -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto "${rdp_sources[@]}" \
  Tests/Integration/RDP/gfx_fallback.m -o "$fixture_root/client"
for mode in retry cancel; do
  export FARCAST_RDP_CONFIG="$fixture_root/config-$mode"
  ( cd "$(dirname "$fixture_server")"; FARCAST_FIXTURE_GFX_FALLBACK=1 exec "$fixture_server" --port=33989 --cert="$fixture_root/cert.pem" --key="$fixture_root/key.pem" ) > "$fixture_root/server-$mode.log" 2>&1 &
  peer=$!
  fixture_pids+=("$peer")
  sleep 0.5
  if ! "$fixture_root/client" 33989 "$mode"; then
    tail -35 "$fixture_root/server-$mode.log"
    exit 1
  fi
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
done
