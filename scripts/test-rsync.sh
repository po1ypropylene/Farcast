#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rsync
mkdir "$fixture_root/input"
dd if=/dev/urandom of="$fixture_root/input/leaf" bs=8192 count=21 2>/dev/null
xcrun clang -O2 Helpers/Rsync/bridge.c -o "$fixture_root/FarcastRsync"
xcrun clang -fobjc-arc -I Farcast/Native/SSH -I Vendor/Native/include -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -lssh2 "${ssh_sources[@]}" Tests/Integration/SSH/rsync_integration.m -o "$fixture_root/client"
.dependencies/test-venv/bin/python Tests/Integration/SSH/ssh_fixture.py "$fixture_root" rsync > "$fixture_root/server.log" 2>&1 &
fixture_pids+=("$!")
for ((i=0; i<120; i++)); do [[ -f "$fixture_root/port" ]] && break; sleep 0.05; done
"$fixture_root/client" "$(cat "$fixture_root/port")" "$fixture_root" "$(cat "$fixture_root/fingerprint")" "$PWD/.dependencies/rsync/rsync"
cmp "$fixture_root/input/leaf" "$fixture_root/output/leaf"
echo "PASS compressed rsync folder round trip, quoted remote path and overwrite confirmation"

# Repeat with the signed Release executables inside a disposable sandboxed parent.
release="$PWD/.build/Xcode/Build/Products/Release/Farcast.app"
app="$fixture_root/Probe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
cp "$fixture_root/client" "$app/Contents/MacOS/Probe"
cp "$release/Contents/MacOS/"{FarcastRsync,rsync} "$app/Contents/MacOS/"
cp "$release/Contents/Frameworks/"*.dylib "$app/Contents/Frameworks/"
cp "$release/Contents/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.peterpo.farcast.rsyncfixture "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Probe "$app/Contents/Info.plist"
install_name_tool -change "$PWD/Vendor/Native/lib/libssh2.1.dylib" @rpath/libssh2.1.dylib "$app/Contents/MacOS/Probe"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Probe"
codesign -d --entitlements - --xml "$release" > "$fixture_root/rights.plist" 2>/dev/null
codesign --force --sign "$(python3 scripts/local-signing.py select)" --entitlements "$fixture_root/rights.plist" "$app"
"$app/Contents/MacOS/Probe" "$(cat "$fixture_root/port")" --sandbox "$(cat "$fixture_root/fingerprint")" "$app/Contents/MacOS/rsync"
echo "PASS signed sandboxed rsync and bridge round trip"
"$app/Contents/MacOS/Probe" "$(cat "$fixture_root/port")" --sandbox "$(cat "$fixture_root/fingerprint")" /usr/bin/rsync
echo "PASS macOS system rsync interoperability"
