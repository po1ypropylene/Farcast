#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh ssh-forwarding-session
products="$PWD/.build/Xcode/Build/Products/Release"
"${FARCAST_TEST_PYTHON:-.dependencies/test-venv/bin/python}" Tests/Integration/SSH/ssh_fixture.py "$fixture_root" forward-only > "$fixture_root/server.log" 2>&1 &
fixture_pids+=("$!")
for ((i=0; i<100; i++)); do [[ -f "$fixture_root/port" ]] && break; sleep 0.05; done
compile_native_clients
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(rg --files Farcast -g '*.swift' | rg -v '^Farcast/App/' | sort)
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 -I "$products" -import-objc-header Farcast/Native-Bridge.h \
  "${sources[@]}" Tests/Integration/Workspace/SSHForwardingSessionChecks.swift \
  "$fixture_root/SSH.o" "$fixture_root/RDP.o" "$fixture_root/RDPClipboard.o" "$fixture_root/RDPDrive.o" "$products/SwiftTerm.o" \
  -L Vendor/Native/lib -lssh2 -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto -lssl -lz -lsrtp2 -framework VideoToolbox -framework CoreMedia -framework CoreVideo -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" -o "$fixture_root/client"
"$fixture_root/client" "$(cat "$fixture_root/port")" "$fixture_root/fingerprint" "$fixture_root"
