#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp-keyboard
xcrun swiftc -target arm64-apple-macos27.0 -parse-as-library \
  Farcast/Domain/RDPDisplayMode.swift \
  Farcast/Domain/RDPDisplayLayout.swift Farcast/Domain/RDPResizeCoordinator.swift \
  Farcast/Protocols/RDP/RDPDesktopView.swift Tests/Integration/RDP/keyboard.swift \
  -o "$fixture_root"/keyboard
"$fixture_root"/keyboard
