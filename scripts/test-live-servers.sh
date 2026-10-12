#!/bin/bash
# Secrets are read in memory from the local file, never passed as command arguments.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple silicon is required.' >&2; exit 1; }
[[ -f Vendor/Native/lib/libfreerdp3.3.dylib ]] || { echo 'Build the native dependencies first.' >&2; exit 1; }
source scripts/test-support.sh live-servers
xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 \
  -I Farcast/Native/SSH -I Farcast/Native/RDP -I Vendor/Native/include \
  -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" \
  -framework Foundation -framework AppKit -framework Security -lssh2 -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto \
  Farcast/Native/SSH/SSHClient.m Farcast/Native/RDP/RDPClient.m Farcast/Native/RDP/RDPClipboard.m Farcast/Native/RDP/RDPDrive.m \
  Tests/Integration/Live/live_servers.m -o "${FARCAST_PROBE_CLIENT:-$fixture_root/client}"
probe_options=()
[[ "${FARCAST_TEST_CONFIGURED:-0}" != 1 ]] || probe_options+=(--configured)
[[ "${FARCAST_TEST_SFTP:-0}" != 1 ]] || probe_options+=(--sftp)
[[ "${FARCAST_TEST_RDP:-0}" != 1 ]] || probe_options+=(--rdp-only)
[[ "${FARCAST_TEST_RDP_FULLSCREEN:-0}" != 1 ]] || probe_options+=(--rdp-full-screen)
[[ "${FARCAST_TEST_RDP_RETINA:-0}" != 1 ]] || probe_options+=(--rdp-retina)
[[ -z "${FARCAST_TEST_SERVER:-}" ]] || probe_options+=("--server=$FARCAST_TEST_SERVER")
# Library logging may contain server details, so suppress it for real credentials.
WLOG_LEVEL=OFF FARCAST_RDP_CONFIG="$fixture_root/config" \
  "${FARCAST_PROBE_CLIENT:-$fixture_root/client}" "${1:-$PWD/.local-testing/servers.json}" ${probe_options[@]+"${probe_options[@]}"} 2>/dev/null
