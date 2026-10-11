#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh sftp-terminal-latency
python_bin="${FARCAST_TEST_PYTHON:-.dependencies/test-venv/bin/python}"
"$python_bin" Tests/Integration/SSH/ssh_fixture.py "$fixture_root" > "$fixture_root/server.log" 2>&1 &
fixture_pids+=("$!")
for ((i=0; i<100; i++)); do [[ -f "$fixture_root/port" ]] && break; sleep 0.05; done
"$python_bin" Tests/Integration/SSH/sftp_latency_proxy.py "$(cat "$fixture_root/port")" "$fixture_root/proxy-port" 60 512 > "$fixture_root/proxy.log" 2>&1 &
fixture_pids+=("$!")
for ((i=0; i<100; i++)); do [[ -f "$fixture_root/proxy-port" ]] && break; sleep 0.05; done
sources=(Farcast/Native/SSH/SSHClient.m)
[[ $# == 0 ]] || { [[ $# == 1 && -f "$1" ]] || exit 2; sources=("$1" "${sources[@]}"); }
for source in "${sources[@]}"; do
    xcrun clang -fobjc-arc -Wno-deprecated-declarations -mmacosx-version-min=27.0 \
      -I Farcast/Native/SSH -I Vendor/Native/include -L Vendor/Native/lib \
      -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -lssh2 \
      "$source" Tests/Integration/SSH/sftp_terminal_latency.m -o "$fixture_root/client"
    options=()
    [[ "$source" == Farcast/Native/SSH/SSHClient.m ]] || options=(report-only)
    "$fixture_root/client" "$(cat "$fixture_root/proxy-port")" "$fixture_root" "$fixture_root/fingerprint" synthetic ${options[@]+"${options[@]}"}
done
