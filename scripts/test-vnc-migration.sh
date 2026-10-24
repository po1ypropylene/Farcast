#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh vnc-migration
python3 - "$fixture_root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
saved = Path('Farcast/Persistence/SavedConnection.swift').read_text()
saved = '\n'.join(line for line in saved.splitlines() if 'vncRemoteIsMac' not in line)+'\n'
(root/'SavedConnection.swift').write_text(saved)
draft = Path('Farcast/Domain/ConnectionDraft.swift').read_text().replace('vncRemoteIsMac = saved.vncRemoteIsMac ?? false', 'vncRemoteIsMac = false')
(root/'ConnectionDraft.swift').write_text(draft)
PY
domain=()
for path in Farcast/Domain/*.swift; do
  [[ "$path" == Farcast/Domain/ConnectionDraft.swift ]] || domain+=("$path")
done
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 -D BEFORE_MAC_VNC \
  "${domain[@]}" "$fixture_root/ConnectionDraft.swift" "$fixture_root/SavedConnection.swift" \
  Farcast/Shared/Security/BoundedZIP.swift Tests/Integration/Migration/VNCMacMetadataChecks.swift -o "$fixture_root/before"
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 \
  Farcast/Domain/*.swift Farcast/Persistence/SavedConnection.swift Farcast/Shared/Security/BoundedZIP.swift \
  Tests/Integration/Migration/VNCMacMetadataChecks.swift -o "$fixture_root/after"
"$fixture_root/before" "$fixture_root/library.store"
"$fixture_root/after" "$fixture_root/library.store"
"$fixture_root/after" "$fixture_root/library.store" reopen
