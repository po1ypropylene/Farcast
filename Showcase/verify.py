#!/usr/bin/env python3
"""Verify the showcase with the production bundle checks, using its separate identity."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]).resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
config = (root / 'Version.xcconfig').read_text()
for setting, key in [('MARKETING_VERSION', 'CFBundleShortVersionString'),
                     ('CURRENT_PROJECT_VERSION', 'CFBundleVersion')]:
    match = re.search(rf'^\s*{setting}\s*=\s*([^\s/]+)', config, re.MULTILINE)
    if not match or match[1] != info.get(key):
        raise SystemExit('Demo app does not match Version.xcconfig. Rebuild with Showcase/build.sh.')
source = (root / 'scripts/verify-bundle.py').read_text()
source = source.replace("'CFBundleIdentifier': 'com.peterpo.farcast'",
                        "'CFBundleIdentifier': 'com.peterpo.farcast.showcase'")
# Keep __file__ at the original verifier so license checks use the repository root.
exec(compile(source, str(root / 'scripts/verify-bundle.py'), 'exec'),
     {'__file__': str(root / 'scripts/verify-bundle.py'), '__name__': '__main__'})
try:
    result = subprocess.run([str(app / 'Contents/MacOS/Farcast'), '--verify-showcase'], timeout=25)
except subprocess.TimeoutExpired:
    raise SystemExit('Demo session verification timed out; the previous demo was not replaced.')
if result.returncode:
    raise SystemExit('Demo session verification failed; the previous demo was not replaced.')
print(f"PASS demo version: {info['CFBundleShortVersionString']} build {info['CFBundleVersion']}")
production = root / '.build/Xcode/Build/Products/Release/Farcast.app'
if production.exists():
    binary = (production / 'Contents/MacOS/Farcast').read_bytes()
    for marker in [b'ShowcaseLibrary', b'startShowcase', b'cortex.star-labs.example', b'--showcase-view=']:
        if marker in binary:
            raise SystemExit('Showcase content found in the production executable.')
    if (production / 'Contents/Resources/catalog.json').exists():
        raise SystemExit('Showcase catalog found in the production resources.')
    print('PASS production bundle contains no showcase symbols, launch options or catalog.')
