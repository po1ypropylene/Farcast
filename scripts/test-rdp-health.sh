#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp-health
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
server_pid=$!
fixture_pids+=("$server_pid")
sleep 0.3
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 \
  -I Farcast/Native/RDP -I Vendor/Native/include -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -framework Security \
  -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto "${rdp_sources[@]}" \
  Tests/Integration/RDP/connection_health.m -o "$fixture_root/client"
"$fixture_root/client" "$port" "$server_pid"
