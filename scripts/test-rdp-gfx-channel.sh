#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp-gfx-channel
xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 \
  -I Farcast/Native/RDP -I Vendor/Native/include -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -framework Security \
  -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto "${rdp_support_sources[@]}" \
  Tests/Integration/RDP/gfx_channel.m -o "$fixture_root/client"
"$fixture_root/client"

# Reproduce the former dispatch bug with the same context and event. Only the
# handler's name comparison changes; this control must fail before codec setup.
python3 - "$fixture_root" <<'PYCONTROL'
from pathlib import Path
import json
import sys
root = Path(sys.argv[1])
source = Path('Farcast/Native/RDP/RDPClient.m').read_text()
needle = '!strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME)'
assert source.count(needle) == 2
adapter = root / 'old-dispatch.m'
adapter.write_text(source.replace(needle, '!strcmp(event->name, "rdpgfx")'))
test = Path('Tests/Integration/RDP/gfx_channel.m').read_text()
(root / 'negative.m').write_text(test.replace('"../../../Farcast/Native/RDP/RDPClient.m"', json.dumps(str(adapter))))
PYCONTROL
xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 \
  -I Farcast/Native/RDP -I Vendor/Native/include -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  -L Vendor/Native/lib -Wl,-rpath,"$PWD/Vendor/Native/lib" -framework Foundation -framework Security \
  -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto "${rdp_support_sources[@]}" \
  "$fixture_root/negative.m" -o "$fixture_root/negative"
if "$fixture_root/negative"; then
  echo 'FAIL old channel dispatch unexpectedly initialized graphics' >&2
  exit 1
else
  status=$?
  [[ "$status" == 2 ]] || exit "$status"
  echo 'PASS old short-name dispatch fails the same GFX initialization regression'
fi
