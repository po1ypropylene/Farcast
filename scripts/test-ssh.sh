#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh ssh
rm -f "$fixture_root"/port
python_bin="${FARCAST_TEST_PYTHON:-.dependencies/test-venv/bin/python}"
"$python_bin" Tests/Integration/SSH/ssh_fixture.py "$fixture_root" > "$fixture_root"/server.log 2>&1 &
fixture_pid=$!
fixture_pids+=("$!")
for ((i=0; i<100; i++)); do [[ -f "$fixture_root"/port ]] && break; sleep 0.05; done
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Farcast/Native/SSH -I Farcast/Native/RDP -I Vendor/Native/include -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -lssh2 "${ssh_sources[@]}" Tests/Integration/SSH/ssh_integration.m -o "$fixture_root"/client
fixture_port=$(cat "$fixture_root"/port)
for mode in password key ed25519 interactive bad-password reject cancel; do
  key_file="$fixture_root"/user-key.pem
  [[ "$mode" != ed25519 ]] || key_file="$fixture_root"/ed25519-key
  "$fixture_root"/client "$mode" "$fixture_port" "$key_file"
done

# Reuse the same fixture source for distinct server authentication policies.
for policy in keyboard-password password-fallback keyboard-mfa keyboard-code keyboard-echo key-only none-auth; do
  kill "$fixture_pid" 2>/dev/null || true
  wait "$fixture_pid" 2>/dev/null || true
  rm -f "$fixture_root/port"
  "$python_bin" Tests/Integration/SSH/ssh_fixture.py "$fixture_root" "$policy" > "$fixture_root/$policy.log" 2>&1 &
  fixture_pid=$!
  fixture_pids+=("$!")
  for ((i=0; i<100; i++)); do [[ -f "$fixture_root/port" ]] && break; sleep 0.05; done
  fixture_port=$(cat "$fixture_root/port")
  "$fixture_root/client" "$policy" "$fixture_port" "$fixture_root/user-key.pem"
  if [[ "$policy" == keyboard-password ]]; then
    "$fixture_root/client" bad-keyboard-password "$fixture_port" "$fixture_root/user-key.pem"
    "$fixture_root/client" reject "$fixture_port" "$fixture_root/user-key.pem"
  elif [[ "$policy" == keyboard-mfa ]]; then
    "$fixture_root/client" interactive "$fixture_port" "$fixture_root/user-key.pem"
  elif [[ "$policy" == keyboard-code ]]; then
    "$fixture_root/client" cancel-prompt "$fixture_port" "$fixture_root/user-key.pem"
  fi
done
