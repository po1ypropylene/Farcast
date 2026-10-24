#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh vnc-apple
python_bin="${FARCAST_TEST_PYTHON:-.dependencies/test-venv/bin/python}"
xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 -I Vendor/Native/include \
  Farcast/Native/VNC/*.m Tests/Integration/VNC/apple_vnc_integration.m \
  -framework Foundation -framework Security -L Vendor/Native/lib -lcrypto -lssl -lz \
  -Wl,-rpath,"$PWD/Vendor/Native/lib" -o "$fixture_root/client"
for mode in success desktop-size trust-refusal bad-group bad-proof bad-integrity; do
  root="$fixture_root/$mode"
  mkdir -p "$root"
  "$python_bin" Tests/Integration/VNC/apple_vnc_fixture.py "$root" "$mode" > "$root/server.log" 2>&1 &
  fixture_pids+=("$!")
  for ((i=0; i<100; i++)); do [[ -f "$root/port" ]] && break; sleep .05; done
  "$fixture_root/client" "$(cat "$root/port")" "$mode" "$root"
  for ((i=0; i<100; i++)); do [[ -f "$root/result" ]] && break; sleep .05; done
  [[ "$(cat "$root/result")" == PASS ]] || { cat "$root/server.log"; exit 1; }
done
