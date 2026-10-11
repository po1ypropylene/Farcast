#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh display-migration
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 \
  Tests/Integration/RDP/DisplayMigrationLegacy.swift -o "$fixture_root/legacy"
"$fixture_root/legacy" "$fixture_root/store"
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 \
  Farcast/Domain/*.swift Farcast/Persistence/SavedConnection.swift \
  Tests/Integration/RDP/DisplayMigrationChecks.swift -o "$fixture_root/current"
"$fixture_root/current" "$fixture_root/store"
