#!/bin/bash
# Exercise the protected-file probe against synthetic servers only.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
source scripts/test-support.sh live-fixtures
mkdir -p "$fixture_root/ssh"
rm -f "$fixture_root/ssh/port"
python_bin="${FARCAST_TEST_PYTHON:-.dependencies/test-venv/bin/python}"
"$python_bin" Tests/Integration/SSH/ssh_fixture.py "$fixture_root/ssh" > "$fixture_root/ssh.log" 2>&1 &
ssh_pid=$!
fixture_pids+=("$!")
rdp_pid=''
for ((i=0; i<100; i++)); do [[ -f "$fixture_root/ssh/port" ]] && break; sleep 0.05; done
fixture_server="$PWD/.dependencies/rdp-fixture/build/server/Sample/sfreerdp-server"
[[ -x "$fixture_server" ]] || scripts/prepare-rdp-fixture.sh
Vendor/Native/bin/openssl req -config /dev/null -x509 -newkey rsa:2048 -nodes \
  -keyout "$fixture_root/key.pem" -out "$fixture_root/cert.pem" -days 1 -subj /CN=localhost > "$fixture_root/cert.log" 2>&1
( cd "$(dirname "$fixture_server")"; exec env -u FARCAST_FIXTURE_NLA -u FARCAST_FIXTURE_SAM \
  "$fixture_server" --port=33988 --cert="$fixture_root/cert.pem" --key="$fixture_root/key.pem" ) > "$fixture_root/rdp.log" 2>&1 &
rdp_pid=$!
fixture_pids+=("$!")
sleep 0.5
python3 - "$fixture_root" <<'PY'
import base64, hashlib, json, os, ssl, sys
from pathlib import Path
root = Path(sys.argv[1])
ssh = dict(id='58C79947-6D5B-4515-8B76-1729C2D30A61', enabled=True, name='Synthetic SSH', protocol='SSH',
           host='127.0.0.1', port=int((root/'ssh/port').read_text()), username='fixture', password='fixture-password',
           expectedFingerprint=(root/'ssh/fingerprint').read_text().strip())
der = ssl.PEM_cert_to_DER_cert((root/'cert.pem').read_text())
rdp = dict(id='A92F52E2-3EC6-4B91-AD2A-78B07DF02DD0', enabled=True, name='Synthetic RDP', protocol='RDP',
           host='127.0.0.1', port=33988, username='fixture', password='fixture-password',
           expectedFingerprint='SHA256:'+base64.b64encode(hashlib.sha256(der).digest()).decode().rstrip('='))
for name, entries in [('servers.json', [ssh, rdp]), ('wrong-pin.json', [dict(ssh, expectedFingerprint='SHA256:wrong')]),
                      ('invalid.json', [dict(ssh, id=123)])]:
    (root/name).write_text(json.dumps(dict(schemaVersion=1, servers=entries)))
    os.chmod(root/name, 0o600)
PY
export FARCAST_PROBE_CLIENT="$fixture_root/client"
scripts/test-live-servers.sh "$fixture_root/servers.json" > "$fixture_root/default-probe.log"
rg -q '^PASS server 1 \(SSH\)' "$fixture_root/default-probe.log"
rg -q '^PASS server 2 \(RDP\)' "$fixture_root/default-probe.log"
cat "$fixture_root/default-probe.log"
for mode in plain retina; do
  options=(--rdp-full-screen)
  [[ "$mode" != retina ]] || options+=(--rdp-retina)
  if ! WLOG_LEVEL=OFF FARCAST_RDP_CONFIG="$fixture_root/fullscreen-$mode" \
    "$fixture_root/client" "$fixture_root/servers.json" "${options[@]}" > "$fixture_root/fullscreen-$mode.log" 2>/dev/null; then
    cat "$fixture_root/fullscreen-$mode.log"
    exit 1
  fi
  rg -Fq 'PASS server 2 (RDP)' "$fixture_root/fullscreen-$mode.log"
  [[ $(wc -l < "$fixture_root/fullscreen-$mode.log") == 1 ]]
done
echo 'PASS RDP-only full-screen probes retain trust and verify exact plain/Retina geometry'
WLOG_LEVEL=OFF "$fixture_root/client" "$fixture_root/servers.json" --server=1 --sftp 2>/dev/null
if WLOG_LEVEL=OFF FARCAST_TEST_SSH_PIN=SHA256:wrong \
  "$fixture_root/client" "$fixture_root/servers.json" --server=1 --sftp > "$fixture_root/pin-override.log" 2>/dev/null; then
  echo 'FAIL live probe accepted a mismatched supplied pin.' >&2; exit 1
fi
echo 'PASS live probe rejects mismatched supplied pin.'
for negative in wrong-pin invalid; do
  if WLOG_LEVEL=OFF "$fixture_root/client" "$fixture_root/$negative.json" > "$fixture_root/$negative.log" 2>/dev/null; then
    echo "FAIL live probe $negative was accepted." >&2; exit 1
  fi
  echo "PASS live probe rejects $negative."
done

# A supplied public pin applies only to the selected entry; no credential-file edit.
FARCAST_TEST_SSH_PIN="$(cat "$fixture_root/ssh/fingerprint")" WLOG_LEVEL=OFF \
  "$fixture_root/client" "$fixture_root/wrong-pin.json" --server=1 --sftp 2>/dev/null
for invalid_options in '--server=99' '--server=2 --sftp'; do
  if WLOG_LEVEL=OFF "$fixture_root/client" "$fixture_root/servers.json" $invalid_options > "$fixture_root/selector.log" 2>/dev/null; then
    echo 'FAIL live probe accepted an invalid SFTP selection.' >&2; exit 1
  fi
done
echo 'PASS live probe rejects missing/non-SSH SFTP selections.'

for policy in keyboard-no-shell shell-eof; do
  kill "$ssh_pid" 2>/dev/null || true
  wait "$ssh_pid" 2>/dev/null || true
  rm -f "$fixture_root/ssh/port"
  "$python_bin" Tests/Integration/SSH/ssh_fixture.py "$fixture_root/ssh" "$policy" > "$fixture_root/$policy-server.log" 2>&1 &
  ssh_pid=$!
  fixture_pids+=("$!")
  for ((i=0; i<100; i++)); do [[ -f "$fixture_root/ssh/port" ]] && break; sleep 0.05; done
  python3 - "$fixture_root" <<'PY'
import json, os, sys
from pathlib import Path
root = Path(sys.argv[1])
document = json.loads((root/'servers.json').read_text())
document['servers'][0]['port'] = int((root/'ssh/port').read_text())
document['servers'][0]['expectedFingerprint'] = (root/'ssh/fingerprint').read_text().strip()
(root/'servers.json').write_text(json.dumps(document))
os.chmod(root/'servers.json', 0o600)
PY
  WLOG_LEVEL=OFF "$fixture_root/client" "$fixture_root/servers.json" --server=1 --sftp > "$fixture_root/$policy-probe.log" 2>/dev/null
  if ! rg -q 'file transfer only' "$fixture_root/$policy-probe.log"; then
    echo 'FAIL live probe did not detect file-only capability.' >&2; exit 1
  fi
  cat "$fixture_root/$policy-probe.log"
done
