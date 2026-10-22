#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh wireguard-migration
python3 - "$fixture_root" <<'PY'
from pathlib import Path
import sys, re
out = Path(sys.argv[1])
# Reconstruct the pre-feature models by removing optional tunnel/display selections.
for name in ['Domain/ConnectionDraft.swift', 'Persistence/SavedConnection.swift']:
    source = Path('Farcast') / name
    text = source.read_text()
    # This computed property uses display fields omitted from the baseline model.
    text = re.sub(r"    var effectiveDisplayMode: RDPDisplayMode \{.*?\n    \}\n", "", text, flags=re.S)
    text = re.sub(r"        if let data = saved.rdpFolderExports \{.*?\n        \}", "", text, flags=re.S)
    text = re.sub(r"        if kind == \.rdp \{.*?\n        \}", "", text, flags=re.S)
    text = re.sub(r"        if let data = saved.sshForwardingRules \{.*?\n        \}", "", text, flags=re.S)
    text = re.sub(r"        if kind == \.ssh \{.*?\n        \}", "", text, flags=re.S)
    text = ''.join(line for line in text.splitlines(True) if not any(field in line for field in ['wireGuardID', 'displayMode', 'rdpDisplayMode', 'rdpFolderExports', 'redirectedFolders', 'forwardingRules', 'sshForwardingRules']))
    (out / source.name).write_text(text)
PY
common=(Farcast/Domain/RDPFolderExport.swift Farcast/Domain/RDPDisplayMode.swift Farcast/Domain/RemoteProtocol.swift Farcast/Domain/SSHAuthentication.swift Farcast/Domain/SSHForwardingRule.swift Farcast/Persistence/ConnectionFolder.swift Tests/Integration/WireGuard/migration.swift)
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 -D BASELINE "${common[@]}" "$fixture_root/ConnectionDraft.swift" "$fixture_root/SavedConnection.swift" -o "$fixture_root/baseline"
xcrun swiftc -parse-as-library -module-name Farcast -target arm64-apple-macos27.0 "${common[@]}" Farcast/Domain/ConnectionDraft.swift Farcast/Persistence/SavedConnection.swift Farcast/Persistence/SavedWireGuard.swift Farcast/Domain/WireGuardConfiguration.swift -o "$fixture_root/current"
"$fixture_root/baseline" "$fixture_root/library.store"
"$fixture_root/current" "$fixture_root/library.store"
"$fixture_root/current" "$fixture_root/library.store" reopen
