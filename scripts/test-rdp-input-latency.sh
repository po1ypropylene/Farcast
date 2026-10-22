#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp-input-latency
fixture_server="$PWD/.dependencies/rdp-fixture/build/server/Sample/sfreerdp-server"
Vendor/Native/bin/openssl req -config /dev/null -x509 -newkey rsa:2048 -nodes \
  -keyout "$fixture_root/key.pem" -out "$fixture_root/cert.pem" -days 1 -subj /CN=localhost > "$fixture_root/cert.log" 2>&1
export FARCAST_RDP_CONFIG="$fixture_root/config"
( cd "$(dirname "$fixture_server")"; exec "$fixture_server" --port=33989 --cert="$fixture_root/cert.pem" --key="$fixture_root/key.pem" ) > "$fixture_root/server.log" 2>&1 &
fixture_pids+=("$!")
sleep 0.5
adapter="${1:-Farcast/Native/RDP/RDPClient.m}"
if [[ "$adapter" == --polling-baseline ]]; then
  adapter="$fixture_root/polling-baseline.m"
  python3 - "$adapter" <<'PYBASE'
from pathlib import Path
import sys
source = Path('Farcast/Native/RDP/RDPClient.m').read_text()
needle = '_inputEvent = CreateEvent(NULL, TRUE, FALSE, NULL);'
assert source.count(needle) == 1
Path(sys.argv[1]).write_text(source.replace(needle, '_inputEvent = NULL;'))
PYBASE
fi
xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 \
  -I Farcast/Native/RDP -I Vendor/Native/include -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -framework Security \
  -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto "$adapter" "${rdp_support_sources[@]}" \
  Tests/Integration/RDP/input_wakeup.m -o "$fixture_root/client"
"$fixture_root/client" 33989
