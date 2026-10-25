#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh apple-negotiation
xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 \
  Tests/Integration/VNC/apple_negotiation_metadata.m -framework Foundation -o "$fixture_root/probe"
"$fixture_root/probe"
