#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp
fixture_server="${FARCAST_RDP_FIXTURE:-.dependencies/rdp-fixture/build/server/Sample/sfreerdp-server}"
[[ -x "$fixture_server" ]] || scripts/prepare-rdp-fixture.sh
Vendor/Native/bin/openssl req -config /dev/null -x509 -newkey rsa:2048 -nodes -keyout "$fixture_root"/key.pem -out "$fixture_root"/cert.pem -days 1 -subj /CN=localhost > "$fixture_root"/cert.log 2>&1
fixture_port=33987
fixture_server="$(cd "$(dirname "$fixture_server")" && pwd)/$(basename "$fixture_server")"
export FARCAST_RDP_CONFIG="$fixture_root/config"
export FARCAST_FIXTURE_DISPLAY=1
export FARCAST_FIXTURE_DRIVE_BOTH=1
export FARCAST_FIXTURE_DRIVE_DIRECTORY_SUFFIX=1
( cd "$(dirname "$fixture_server")"; exec "$fixture_server" --port="$fixture_port" --cert="$fixture_root/cert.pem" --key="$fixture_root/key.pem" ) > "$fixture_root"/server.log 2>&1 &
fixture_pid=$!
fixture_pids+=("$!")
sleep 0.5
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Farcast/Native/SSH -I Farcast/Native/RDP -I Vendor/Native/include -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -framework Security -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto "${rdp_sources[@]}" Tests/Integration/RDP/rdp_integration.m -o "$fixture_root"/client
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -Wno-deprecated-declarations \
  -I Farcast/Native/RDP -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -lfreerdp3 -lwinpr3 \
  Tests/Integration/RDP/display_settings.m -o "$fixture_root/display-settings"
"$fixture_root/display-settings"
modes=(accept keyboard keyboard-paused reject cancel input-overflow pointer-burst clipboard files drive drive-ro monitors retina)
[[ -z "${FARCAST_FIXTURE_NLA:-}" ]] || modes+=(bad-password)
for mode in "${modes[@]}"; do "$fixture_root"/client "$mode" "$fixture_port"; done

for evidence in 'monitor definitions and mixed DPI' 'left-monitor pointer' 'primary-monitor pointer' 'Retina core geometry and scale'; do
  rg -q "PASS display wire $evidence" "$fixture_root/server.log" || { echo "FAIL RDP display wire $evidence" >&2; exit 1; }
done
echo 'PASS RDP peer decoded monitor layout, Retina scales and pointer coordinates'

[[ "$(rg -c 'PASS keyboard wire scan codes, repeats, extended keys, Unicode pairs and toggle synchronization' "$fixture_root/server.log")" == 2 ]] || { echo 'FAIL RDP keyboard wire sequence or pause/resume delivery' >&2; exit 1; }
echo 'PASS RDP peer decoded ordered keyboard and toggle events'
