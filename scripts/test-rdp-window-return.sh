#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp-window-return
xcrun swiftc -target arm64-apple-macos27.0 -parse-as-library \
  Farcast/Domain/RDPDisplayMode.swift Farcast/Domain/RDPDisplayLayout.swift \
  Farcast/Domain/RDPResizeCoordinator.swift Farcast/Protocols/RDP/RDPDesktopView.swift \
  Tests/Integration/Workspace/WindowReturnChecks.swift -o "$fixture_root/client"
"$fixture_root/client"
