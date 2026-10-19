#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh sidebar-migration
# Compile the exact pre-sidebar schema under the same module/entity names.
python3 - "$fixture_root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name, fields in {
    'ConnectionFolder.swift': ['    var parentID: UUID? = nil\n', '    var isCollapsed: Bool? = nil\n'],
    'SavedConnection.swift': ['    var favoriteOrder: Int? = nil\n'],
}.items():
    text = (Path('Farcast/Persistence') / name).read_text()
    for field in fields:
        assert text.count(field) == 1
        text = text.replace(field, '')
    (root / name).write_text(text)
PY
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 -D BEFORE_SIDEBAR \
  Farcast/Domain/*.swift Farcast/Shared/Security/BoundedZIP.swift "$fixture_root/ConnectionFolder.swift" "$fixture_root/SavedConnection.swift" \
  Tests/Integration/Migration/SidebarMetadataChecks.swift -o "$fixture_root/before"
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 \
  Farcast/Domain/*.swift Farcast/Shared/Security/BoundedZIP.swift Farcast/Persistence/ConnectionFolder.swift Farcast/Persistence/SavedConnection.swift \
  Tests/Integration/Migration/SidebarMetadataChecks.swift -o "$fixture_root/after"
"$fixture_root/before" "$fixture_root/library.store"
"$fixture_root/after" "$fixture_root/library.store"
