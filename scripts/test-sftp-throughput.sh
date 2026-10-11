#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh sftp-throughput
rm -f "$fixture_root"/port "$fixture_root"/proxy-port
python_bin="${FARCAST_TEST_PYTHON:-.dependencies/test-venv/bin/python}"
"$python_bin" Tests/Integration/SSH/ssh_fixture.py "$fixture_root" > "$fixture_root"/server.log 2>&1 &
server_pid=$!
fixture_pids+=("$!")
proxy_pid=""
for ((i=0;i<100;i++)); do [[ -f "$fixture_root"/port ]] && break; sleep 0.05; done
"$python_bin" Tests/Integration/SSH/sftp_latency_proxy.py "$(cat "$fixture_root"/port)" "$fixture_root"/proxy-port > "$fixture_root"/proxy.log 2>&1 &
proxy_pid=$!
fixture_pids+=("$!")
for ((i=0;i<100;i++)); do [[ -f "$fixture_root"/proxy-port ]] && break; sleep 0.05; done
# Controlled comparison: identical new code, just the previous 32 KiB window.
python3 - "$fixture_root" <<'PY'
from pathlib import Path
import sys
code=Path('Farcast/Native/SSH/SSHClient.m').read_text()
old = 'upload ? 4 * 1024 * 1024 : 1024 * 1024'
assert code.count(old) == 1, 'Upload window changed; update the controlled baseline.'
code=code.replace(old, 'upload ? 32768 : 1024 * 1024')
(Path(sys.argv[1])/'baseline.m').write_text(code)
PY
for mode in baseline pipelined; do
    source="$fixture_root"/baseline.m
    [[ "$mode" == baseline ]] || source=Farcast/Native/SSH/SSHClient.m
    xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Farcast/Native/SSH -I Vendor/Native/include -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -lssh2 "$source" Tests/Integration/SSH/sftp_throughput.m -o "$fixture_root/$mode"
    "$fixture_root/$mode" "$(cat "$fixture_root"/proxy-port)" "$fixture_root" "$fixture_root/fingerprint" > "$fixture_root/$mode-speed"
done
python3 - "$fixture_root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
before=float((root/'baseline-speed').read_text())
after=float((root/'pipelined-speed').read_text())
assert after > before * 2, (before,after)
print(f'PASS simulated 20 ms RTT upload: 32 KiB {before:.2f} MiB/s; 4 MiB {after:.2f} MiB/s; {after/before:.1f}x')
PY
