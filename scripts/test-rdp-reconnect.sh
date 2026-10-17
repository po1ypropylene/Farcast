#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp-reconnect
products="$PWD/.build/Xcode/Build/Products/Release"
server="$PWD/.dependencies/rdp-fixture/build/server/Sample/sfreerdp-server"
[[ -x "$server" ]] || scripts/prepare-rdp-fixture.sh
Vendor/Native/bin/openssl req -config /dev/null -x509 -newkey rsa:2048 -nodes \
  -keyout "$fixture_root/key.pem" -out "$fixture_root/cert.pem" -days 1 -subj /CN=localhost > "$fixture_root/cert.log" 2>&1
port=$(.dependencies/test-venv/bin/python - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    print(s.getsockname()[1])
PY
)
export FARCAST_RDP_CONFIG="$fixture_root/config"
(cd "$(dirname "$server")"; exec "$server" --port="$port" --cert="$fixture_root/cert.pem" --key="$fixture_root/key.pem") > "$fixture_root/server.log" 2>&1 &
fixture_pids+=("$!")
compile_native_clients
session_sources=()
while IFS= read -r source; do session_sources+=("$source"); done < <(rg --files Farcast -g '*.swift' | rg -v '^Farcast/App/' | sort)
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 \
  -I "$products" -import-objc-header Farcast/Native-Bridge.h \
  "${session_sources[@]}" Tests/Integration/Workspace/RDPReconnectSessionChecks.swift \
  "$fixture_root/SSH.o" "$fixture_root/RDP.o" "$fixture_root/RDPClipboard.o" "$fixture_root/RDPDrive.o" "$products/SwiftTerm.o" \
  -L Vendor/Native/lib -lssh2 -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto -lssl -lz \
  -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" -o "$fixture_root/client"
"$fixture_root/client" "$fixture_root" "$port" "$fixture_root/cert.pem"
