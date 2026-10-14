#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh sftp
rm -f "$fixture_root"/port
python_bin="${FARCAST_TEST_PYTHON:-.dependencies/test-venv/bin/python}"
"$python_bin" Tests/Integration/SSH/ssh_fixture.py "$fixture_root" > "$fixture_root"/server.log 2>&1 &
fixture_pid=$!
fixture_pids+=("$!")
for ((i=0; i<100; i++)); do [[ -f "$fixture_root"/port ]] && break; sleep 0.05; done
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Farcast/Native/SSH -I Vendor/Native/include -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -lssh2 "${ssh_sources[@]}" Tests/Integration/SSH/sftp_integration.m -o "$fixture_root"/client
fixture_port=$(cat "$fixture_root"/port)
for mode in roundtrip key interactive empty missing local-collision remote-collision missing-file directory race cancel; do
    "$fixture_root"/client "$mode" "$fixture_port" "$fixture_root" "$fixture_root/fingerprint"
done

xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Farcast/Native/SSH -I Vendor/Native/include -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -lssh2 "${ssh_sources[@]}" Tests/Integration/SSH/sftp_operations.m -o "$fixture_root"/operations
"$fixture_root"/operations "$fixture_port" "$fixture_root" "$fixture_root/fingerprint"

compile_native_adapter "$fixture_root/native.o" "${ssh_sources[@]}"
xcrun swiftc -parse-as-library -target arm64-apple-macos27.0 -import-objc-header Farcast/Native/SSH/SSHClient.h Farcast/Features/Sessions/SFTPController.swift Tests/Integration/SSH/sftp_browsing.swift "$fixture_root"/native.o -L Vendor/Native/lib -lssh2 -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" -o "$fixture_root"/browsing-client
"$fixture_root"/browsing-client
xcrun swiftc -parse-as-library -target arm64-apple-macos27.0 -import-objc-header Farcast/Native/SSH/SSHClient.h Farcast/Features/Sessions/SFTPController.swift Tests/Integration/SSH/sftp_local_operations.swift "$fixture_root"/native.o -L Vendor/Native/lib -lssh2 -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" -o "$fixture_root"/local-operations-client
"$fixture_root"/local-operations-client "$fixture_root"

xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Farcast/Native/SSH -I Vendor/Native/include -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -lssh2 "${ssh_sources[@]}" Tests/Integration/SSH/sftp_cancel.m -o "$fixture_root"/cancel-client
for direction in upload download; do
    "$fixture_root"/cancel-client "$direction" "$fixture_port" "$fixture_root" "$fixture_root/fingerprint"
done

xcrun swiftc -parse-as-library -target arm64-apple-macos27.0 -import-objc-header Farcast/Native/SSH/SSHClient.h Farcast/Features/Sessions/SFTPController.swift Tests/Integration/SSH/sftp_drop_operations.swift "$fixture_root"/native.o -L Vendor/Native/lib -lssh2 -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" -o "$fixture_root"/drop-client
"$fixture_root"/drop-client "$fixture_port" "$fixture_root" "$fixture_root/fingerprint"

xcrun swiftc -parse-as-library -target arm64-apple-macos27.0 -import-objc-header Farcast/Native/SSH/SSHClient.h Farcast/Features/Sessions/SFTPController.swift Tests/Integration/SSH/sftp_conflicts.swift "$fixture_root"/native.o -L Vendor/Native/lib -lssh2 -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" -o "$fixture_root"/conflict-client
"$fixture_root"/conflict-client "$fixture_port" "$fixture_root" "$fixture_root/fingerprint"

kill "$fixture_pid" 2>/dev/null || true
wait "$fixture_pid" 2>/dev/null || true
rm -f "$fixture_root"/port
"$python_bin" Tests/Integration/SSH/ssh_fixture.py "$fixture_root" no-sftp > "$fixture_root"/no-sftp.log 2>&1 &
fixture_pid=$!
fixture_pids+=("$!")
for ((i=0; i<100; i++)); do [[ -f "$fixture_root"/port ]] && break; sleep 0.05; done
fixture_port=$(cat "$fixture_root"/port)
"$fixture_root"/client no-sftp "$fixture_port" "$fixture_root" "$fixture_root/fingerprint"

for mode in no-pty no-shell channel-denied shell-eof no-services keyboard-no-shell; do
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
    rm -f "$fixture_root"/port
    "$python_bin" Tests/Integration/SSH/ssh_fixture.py "$fixture_root" "$mode" > "$fixture_root/$mode.log" 2>&1 &
    fixture_pid=$!
    fixture_pids+=("$!")
    for ((i=0; i<100; i++)); do [[ -f "$fixture_root"/port ]] && break; sleep 0.05; done
    fixture_port=$(cat "$fixture_root"/port)
    "$fixture_root"/client "$mode" "$fixture_port" "$fixture_root" "$fixture_root/fingerprint"
    if [[ "$mode" == no-shell ]]; then
        for direction in upload download; do
            "$fixture_root"/cancel-client "$direction" "$fixture_port" "$fixture_root" "$fixture_root/fingerprint" files-only
        done
    fi
done
