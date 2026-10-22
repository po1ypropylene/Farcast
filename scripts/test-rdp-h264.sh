#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp-h264
xcrun clang -arch arm64 -mmacosx-version-min=27.0 \
  -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  Tests/Integration/RDP/h264_roundtrip.c -L Vendor/Native/lib -lfreerdp3 -lwinpr3 \
  -Wl,-rpath,"$PWD/Vendor/Native/lib" -o "$fixture_root/client"
"$fixture_root/client"
