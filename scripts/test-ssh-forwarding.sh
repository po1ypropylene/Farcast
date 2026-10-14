#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh ssh-forwarding
python_bin="${FARCAST_TEST_PYTHON:-.dependencies/test-venv/bin/python}"
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Farcast/Native/SSH -I Vendor/Native/include -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -lssh2 "${ssh_sources[@]}" Tests/Integration/SSH/ssh_forwarding.m -o "$fixture_root/client"
for mode in forwarding forward-only forward-denied forward-delay forward-timeout; do
    rm -f "$fixture_root/port"
    "$python_bin" Tests/Integration/SSH/ssh_fixture.py "$fixture_root" "$mode" > "$fixture_root/server.log" 2>&1 &
    fixture_pid=$!; fixture_pids+=("$fixture_pid")
    for ((i=0; i<100; i++)); do [[ -f "$fixture_root/port" ]] && break; sleep 0.05; done
    "$python_bin" Tests/Integration/SSH/ssh_forwarding.py "$fixture_root" "$fixture_root/client" "$(cat "$fixture_root/port")" "$mode"
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
done
