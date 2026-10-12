#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp-drives
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I Farcast/Native/RDP \
  -I Vendor/Native/include -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation \
  -lfreerdp3 -lfreerdp-client3 -lwinpr3 "${rdp_drive_sources[@]}" \
  Tests/Integration/RDP/drive_files.m -o "$fixture_root/client"
"$fixture_root/client" "$fixture_root"
