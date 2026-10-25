#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh vnc
python_bin="${FARCAST_TEST_PYTHON:-.dependencies/test-venv/bin/python}"
xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 -I Vendor/Native/include \
  Farcast/Native/VNC/*.m Tests/Integration/VNC/vnc_integration.m \
  -framework Foundation -framework Security -L Vendor/Native/lib -lcrypto -lssl -lz -lsrtp2 -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -Wl,-rpath,"$PWD/Vendor/Native/lib" -o "$fixture_root/client"
for scenario in password:8 password:7 password:3 none:8 none:7 none:3 wrong:8 bounds:8 encoding:8 oversized:8 unsupported:8 tlsvnc:8 tlsplain:8 tlsnone:8 tlsreject:8 tlsanonymous:8; do
  mode="${scenario%:*}"
  version="${scenario#*:}"
  root="$fixture_root/$mode-$version"
  mkdir -p "$root"
  if [[ "$mode" == tls* ]]; then
    Vendor/Native/bin/openssl req -config /dev/null -x509 -newkey rsa:2048 -nodes -keyout "$root/key.pem" -out "$root/cert.pem" -days 1 -subj /CN=localhost > "$root/cert.log" 2>&1
    Vendor/Native/bin/openssl x509 -in "$root/cert.pem" -outform DER -out "$root/cert.der"
  fi
  "$python_bin" Tests/Integration/VNC/vnc_fixture.py "$root" "$mode" "$version" > "$root/server.log" 2>&1 &
  fixture_pids+=("$!")
  for ((i=0; i<100; i++)); do [[ -f "$root/port" ]] && break; sleep 0.05; done
  "$fixture_root/client" "$(cat "$root/port")" "$mode" "$root"
  "$python_bin" - "$root" "$mode" <<'PY'
import json, pathlib, sys, time
root, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
for _ in range(100):
    if (root / 'events-1.json').exists(): break
    time.sleep(.01)
errors = list(root.glob('error-*'))
assert not errors, [p.read_text() for p in errors]
events = json.loads((root / 'events-1.json').read_text())
if mode in ('password', 'none', 'tlsvnc', 'tlsplain', 'tlsnone'):
    keys = [e for e in events if e[0] == 'key']
    expected = [65, 233, 0x01004e2d, 0x0101f600, 0xff09, 0xff0d, 66]
    assert keys[:14] == [["key", down, key] for key in expected for down in (1, 0)]
    assert keys[14:20] == [["key", 1, k] for k in (0xffe3, 0xffe9, 0xffff)] + [["key", 0, k] for k in (0xffff, 0xffe9, 0xffe3)]
    pointers = [e for e in events if e[0] == 'pointer']
    assert pointers[:6] == [['pointer', mask, x, 8] for mask, x in ((1, 7), (1, 9), (0, 9), (0, 11), (8, 11), (0, 11))]
    assert ['pointer', 1, 7, 8] in events and ['pointer', 0, 7, 8] in events
    assert 0 < len(keys[20:]) < 2000 and len(keys[20:]) % 2 == 0
    print('PASS Unicode key pairs, Ctrl+Alt+Delete, pointer and typing cancellation on the wire')
PY
done
