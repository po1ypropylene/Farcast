#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh workspace
xcrun swiftc -parse-as-library -target arm64-apple-macos27.0 \
  Farcast/Domain/*.swift Farcast/Persistence/*.swift \
  Farcast/Shared/Security/*.swift Farcast/Shared/Prompting/*.swift \
  Farcast/Shared/Testing/*.swift Farcast/Features/Connections/EditorRequest.swift \
  Farcast/Features/Workspace/Workspace.swift Farcast/App/AppDelegate.swift \
  Tests/Integration/Workspace/WorkspaceChecks.swift \
  -o "$fixture_root/client"
"$fixture_root/client"
"$fixture_root/client" close-window
"$fixture_root/client" quit

# Exercise the actual main-actor session and native SSH adapter after the fast doubles.
products="$PWD/.build/Xcode/Build/Products/Release"
[[ -f "$products/SwiftTerm.o" ]] || { echo 'Build the Release app before session checks.' >&2; exit 1; }
python_bin="${FARCAST_TEST_PYTHON:-.dependencies/test-venv/bin/python}"
"$python_bin" Tests/Integration/SSH/ssh_fixture.py "$fixture_root" keyboard-no-shell > "$fixture_root/server.log" 2>&1 &
fixture_pids+=("$!")
for ((i=0; i<100; i++)); do [[ -f "$fixture_root/port" ]] && break; sleep 0.05; done
for protocol in SSH RDP; do
  xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Vendor/Native/include \
    -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
    -c "Farcast/Native/$protocol/${protocol}Client.m" -o "$fixture_root/$protocol.o"
done
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Vendor/Native/include \
  -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  -c Farcast/Native/RDP/RDPClipboard.m -o "$fixture_root/RDPClipboard.o"
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Vendor/Native/include \
  -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  -c Farcast/Native/RDP/RDPDrive.m -o "$fixture_root/RDPDrive.o"
session_sources=()
while IFS= read -r source; do session_sources+=("$source"); done < <(rg --files Farcast -g '*.swift' | rg -v '^Farcast/App/' | sort)
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 \
  -I "$products" -import-objc-header Farcast/Native-Bridge.h \
  "${session_sources[@]}" Tests/Integration/Workspace/SSHSessionChecks.swift \
  "$fixture_root/SSH.o" "$fixture_root/RDP.o" "$fixture_root/RDPClipboard.o" "$fixture_root/RDPDrive.o" "$products/SwiftTerm.o" \
  -L Vendor/Native/lib -lssh2 -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto \
  -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" -o "$fixture_root/ssh-session-client"
"$fixture_root/ssh-session-client" "$(cat "$fixture_root/port")" "$fixture_root/fingerprint"

# Verify one-owner native presentation when moving a live surface between windows.
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 \
  -I "$products" -import-objc-header Farcast/Native-Bridge.h \
  "${session_sources[@]}" Tests/Integration/Workspace/PresentationChecks.swift \
  "$fixture_root/SSH.o" "$fixture_root/RDP.o" "$fixture_root/RDPClipboard.o" "$fixture_root/RDPDrive.o" "$products/SwiftTerm.o" \
  -L Vendor/Native/lib -lssh2 -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto \
  -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" -o "$fixture_root/presentation-client"
"$fixture_root/presentation-client"
