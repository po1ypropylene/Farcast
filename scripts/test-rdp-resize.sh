#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp-resize
server="$PWD/.dependencies/rdp-fixture/build/server/Sample/sfreerdp-server"
[[ -x "$server" ]] || scripts/prepare-rdp-fixture.sh
Vendor/Native/bin/openssl req -config /dev/null -x509 -newkey rsa:2048 -nodes -keyout "$fixture_root/key.pem" -out "$fixture_root/cert.pem" -days 1 -subj /CN=localhost > "$fixture_root/cert.log" 2>&1
products="$PWD/.build/Xcode/Build/Products/Release"
compile_native_clients
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(rg --files Farcast -g '*.swift' | rg -v '^Farcast/App/' | sort)
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 -I "$products" -import-objc-header Farcast/Native-Bridge.h \
  "${sources[@]}" Tests/Integration/Workspace/RDPResizeSessionChecks.swift \
  "$fixture_root/SSH.o" "$fixture_root/RDP.o" "$fixture_root/RDPClipboard.o" "$fixture_root/RDPDrive.o" "$products/SwiftTerm.o" \
  -L Vendor/Native/lib -lssh2 -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto -lssl -lz -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" -o "$fixture_root/client"
for mode in apply retina ignored restricted missing; do
  port=$(.dependencies/test-venv/bin/python - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1',0))
    print(s.getsockname()[1])
PY
)
  export FARCAST_RDP_CONFIG="$fixture_root/config-$mode"
  if [[ "$mode" == missing ]]; then unset FARCAST_FIXTURE_RESIZE; else export FARCAST_FIXTURE_RESIZE="$mode"; fi
  (cd "$(dirname "$server")"; exec "$server" --port="$port" --cert="$fixture_root/cert.pem" --key="$fixture_root/key.pem") > "$fixture_root/server-$mode.log" 2>&1 &
  server_pid=$!
  fixture_pids+=("$server_pid")
  sleep 0.2
  if ! "$fixture_root/client" "$port" "$fixture_root/cert.pem" "$fixture_root" "$mode"; then
    tail -n 24 "$fixture_root/server-$mode.log"
    exit 1
  fi
  if [[ "$mode" == apply ]]; then
    rg -q 'PASS resize wire 900x650 scale 100 device 100' "$fixture_root/server-$mode.log"
    rg -q 'PASS resize pointer after reactivation' "$fixture_root/server-$mode.log"
  fi
  kill "$server_pid"
  wait "$server_pid" 2>/dev/null || true
done
echo 'PASS resize peer decoded actual Display Control layouts and post-reactivation pointer input'
