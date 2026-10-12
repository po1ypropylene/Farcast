#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/prepare-wireguard.sh
source scripts/test-support.sh wireguard-lifecycle
mkdir -p "$fixture_root/Lifecycle.app/Contents/MacOS"
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Vendor/Native/include -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -framework Security -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto Tests/Integration/WireGuard/native_identity.m "${rdp_support_sources[@]}" -o "$fixture_root/native-identity"
"$fixture_root/native-identity"
xcrun swiftc -parse-as-library -target arm64-apple-macos27.0 Farcast/Domain/WireGuardConfiguration.swift Farcast/Shared/Security/CredentialStore.swift Farcast/Shared/Security/LocalCredentialStore.swift Farcast/Features/WireGuard/WireGuardTransport.swift Tests/Integration/WireGuard/lifecycle.swift -o "$fixture_root/Lifecycle.app/Contents/MacOS/Lifecycle"
cp Vendor/Native/bin/FarcastWireGuard "$fixture_root/Lifecycle.app/Contents/MacOS/"
cat > "$fixture_root/Lifecycle.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Lifecycle</string><key>CFBundleIdentifier</key><string>com.peterpo.farcast.wireguard-lifecycle</string></dict></plist>
PLIST
python3 - "$fixture_root" <<'PYTEST'
import plistlib, sys
from pathlib import Path
root = Path(sys.argv[1])
(root / 'parent-entitlements.plist').write_bytes(plistlib.dumps({
    'com.apple.security.app-sandbox': True,
    'com.apple.security.network.client': True,
    'com.apple.security.network.server': True,
}))
PYTEST
codesign --force --sign - --entitlements Configuration/WireGuardHelper.entitlements "$fixture_root/Lifecycle.app/Contents/MacOS/FarcastWireGuard"
codesign --force --sign - --entitlements "$fixture_root/parent-entitlements.plist" "$fixture_root/Lifecycle.app"
"$fixture_root/Lifecycle.app/Contents/MacOS/Lifecycle"
