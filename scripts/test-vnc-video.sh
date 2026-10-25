#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh vnc-video
xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 -I Vendor/Native/include \
  Farcast/Native/VNC/VNCAppleMediaOffer.m Farcast/Native/VNC/VNCAppleVideo.m \
  Tests/Integration/VNC/apple_video_integration.m \
  -framework Foundation -framework Security -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -L Vendor/Native/lib -lsrtp2 -lcrypto -lz -Wl,-rpath,"$PWD/Vendor/Native/lib" -o "$fixture_root/client"
"$fixture_root/client"
