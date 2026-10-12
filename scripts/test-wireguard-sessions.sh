#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh wireguard-sessions
products="$PWD/.build/Xcode/Build/Products/Release"
[[ -f "$products/SwiftTerm.o" ]] || { echo 'Build the Release app before session checks.' >&2; exit 1; }
server="$PWD/.dependencies/rdp-fixture/build/server/Sample/sfreerdp-server"
[[ -x "$server" ]] || scripts/prepare-rdp-fixture.sh
mkdir -p "$fixture_root/ssh" "$fixture_root/Sessions.app/Contents/MacOS"
"${FARCAST_TEST_PYTHON:-.dependencies/test-venv/bin/python}" Tests/Integration/SSH/ssh_fixture.py "$fixture_root/ssh" password > "$fixture_root/ssh.log" 2>&1 &
fixture_pids+=("$!")
for ((i=0; i<100; i++)); do [[ -f "$fixture_root/ssh/port" ]] && break; sleep 0.05; done
Vendor/Native/bin/openssl req -config /dev/null -x509 -newkey rsa:2048 -nodes -keyout "$fixture_root/key.pem" -out "$fixture_root/cert.pem" -days 1 -subj /CN=localhost > "$fixture_root/cert.log" 2>&1
port=$(.dependencies/test-venv/bin/python - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    print(s.getsockname()[1])
PY
)
export FARCAST_RDP_CONFIG="$fixture_root/config"
(cd "$(dirname "$server")"; exec "$server" --port="$port" --cert="$fixture_root/cert.pem" --key="$fixture_root/key.pem") > "$fixture_root/rdp.log" 2>&1 &
fixture_pids+=("$!")
compile_native_clients
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(rg --files Farcast -g '*.swift' | rg -v '^Farcast/App/' | sort)
executable="$fixture_root/Sessions.app/Contents/MacOS/Sessions"
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 -I "$products" -import-objc-header Farcast/Native-Bridge.h \
  "${sources[@]}" Tests/Integration/WireGuard/sessions.swift \
  "$fixture_root/SSH.o" "$fixture_root/RDP.o" "$fixture_root/RDPClipboard.o" "$fixture_root/RDPDrive.o" "$products/SwiftTerm.o" \
  -L Vendor/Native/lib -lssh2 -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" -o "$executable"
cp Vendor/Native/bin/FarcastWireGuard "$fixture_root/Sessions.app/Contents/MacOS/"
cat > "$fixture_root/Sessions.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Sessions</string><key>CFBundleIdentifier</key><string>com.peterpo.farcast.wireguard-sessions</string></dict></plist>
PLIST
export FARCAST_WG_SESSION_CLIENT="$executable"
export FARCAST_WG_SESSION_ROOT="$fixture_root"
export FARCAST_WG_SESSION_SSH_PORT="$(cat "$fixture_root/ssh/port")"
export FARCAST_WG_SESSION_RDP_PORT="$port"
export GOCACHE="$PWD/.dependencies/go/build" GOMODCACHE="$PWD/.dependencies/go/modules"
cd Networking/WireGuard
go test -race -count=1 -timeout=180s -run '^TestMixedProtocolSessions$' -v .
