#!/usr/bin/env python3
"""Verify the showcase with the production bundle checks, using its separate identity."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
source = (root / 'scripts/verify-bundle.py').read_text()
source = source.replace("'CFBundleIdentifier': 'com.peterpo.farcast'",
                        "'CFBundleIdentifier': 'com.peterpo.farcast.showcase'")
# Keep __file__ at the original verifier so license checks use the repository root.
exec(compile(source, str(root / 'scripts/verify-bundle.py'), 'exec'),
     {'__file__': str(root / 'scripts/verify-bundle.py'), '__name__': '__main__'})
app = Path(sys.argv[1]).resolve()
subprocess.run([str(app / 'Contents/MacOS/Farcast'), '--verify-showcase'], check=True, timeout=25)
production = root / '.build/Xcode/Build/Products/Release/Farcast.app'
if production.exists():
    binary = (production / 'Contents/MacOS/Farcast').read_bytes()
    for marker in [b'ShowcaseLibrary', b'startShowcase', b'cortex.star-labs.example', b'--showcase-view=']:
        if marker in binary:
            raise SystemExit('Showcase content found in the production executable.')
    if (production / 'Contents/Resources/catalog.json').exists():
        raise SystemExit('Showcase catalog found in the production resources.')
    print('PASS production bundle contains no showcase symbols, launch options or catalog.')
