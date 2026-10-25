#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh vpn-ui
products="$PWD/.build/Xcode/Build/Products/Release"
fixture_app="$fixture_root/Farcast UI Checks.app"
mkdir -p "$fixture_app/Contents/MacOS"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.peterpo.farcast.vpn-ui-checks</string>
<key>CFBundleName</key><string>Farcast UI Checks</string>
<key>CFBundleExecutable</key><string>client</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
compile_native_clients
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(rg --files Farcast -g '*.swift' | rg -v '^Farcast/App/' | sort)
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 -I "$products" -import-objc-header Farcast/Native-Bridge.h \
  "${sources[@]}" Tests/Integration/Workspace/VPNUIReviewChecks.swift \
  "$fixture_root/SSH.o" "$fixture_root/RDP.o" "$fixture_root/RDPClipboard.o" "$fixture_root/RDPDrive.o" "$products/SwiftTerm.o" \
  -L Vendor/Native/lib -lssh2 -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto -lssl -lz -lsrtp2 -framework VideoToolbox -framework CoreMedia -framework CoreVideo -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" -o "$fixture_app/Contents/MacOS/client"
"$fixture_app/Contents/MacOS/client" "$@"
