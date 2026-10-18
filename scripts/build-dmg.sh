#!/bin/bash
# Package the existing verified Release app without rebuilding or changing its version.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == --help && $# == 1 ]]; then
  printf 'Usage: scripts/build-dmg.sh\nRun scripts/build.sh and finish app verification first. Packaging never rebuilds. Outputs a verified DMG and SHA256 file in .build/releases.\nLocal builds use pinned certificate-backed signing and not notarized. Nothing is committed or uploaded.\n'
  exit 0
fi
if [[ $# != 0 ]]; then
  printf 'Usage: scripts/build-dmg.sh [--help]\n' >&2
  exit 1
fi

app="$PWD/.build/Xcode/Build/Products/Release/Farcast.app"
if [[ ! -f "$app/Contents/Info.plist" ]]; then
  printf 'No Release app. Run scripts/build.sh and verify the app before packaging.\n' >&2
  exit 1
fi
# Derive the filename from the actual bundle, never from a second version source.
release_name=$(python3 - "$app/Contents/Info.plist" <<'PY'
from pathlib import Path
import plistlib
import re
import sys

with open(sys.argv[1], 'rb') as file:
    info = plistlib.load(file)
version = info['CFBundleShortVersionString']
build = info['CFBundleVersion']
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[1-9][0-9]*', build):
    raise SystemExit('Set a major.minor.patch version and a positive integer build in Version.xcconfig.')
config = Path('Version.xcconfig').read_text()
for name, actual in [('MARKETING_VERSION', version), ('CURRENT_PROJECT_VERSION', build)]:
    match = re.search(rf'^\s*{name}\s*=\s*([^\s/]+)\s*(?://.*)?$', config, re.MULTILINE)
    if not match or match[1] != actual:
        raise SystemExit('Release app does not match Version.xcconfig. Run scripts/build.sh and verify the app before packaging.')
print(f'Farcast-{version}-build-{build}-arm64')
PY
)

# Verify the existing bundle before staging as well as the mounted copy below.
python3 scripts/verify-bundle.py "$app"
python3 scripts/local-signing.py verify "$app"

mkdir -p .build/releases
work=$(mktemp -d "$PWD/.build/dmg.XXXXXX")
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then
    diskutil eject "$work/mount" >/dev/null || true
  fi
  # Do not remove the mount directory if detaching failed.
  if ! mount | grep -Fq " on $work/mount ("; then
    rm -rf "$work"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$work/payload" "$work/mount"
ditto "$app" "$work/payload/Farcast.app"
cp CHANGELOG.md "$work/payload/CHANGELOG.md"
cp LICENSE "$work/payload/LICENSE"
ln -s /Applications "$work/payload/Applications"
diskutil image create from --volumeName "Farcast" --format UDZO \
  "$work/payload" "$work/$release_name.dmg"
hdiutil verify "$work/$release_name.dmg"
diskutil image attach --readOnly --nobrowse --mountPoint "$work/mount" "$work/$release_name.dmg" >/dev/null
mounted=1
python3 scripts/verify-bundle.py "$work/mount/Farcast.app"
python3 scripts/local-signing.py verify "$work/mount/Farcast.app"
cmp CHANGELOG.md "$work/mount/CHANGELOG.md"
cmp LICENSE "$work/mount/LICENSE"
[[ "$(readlink "$work/mount/Applications")" == /Applications ]]
diskutil eject "$work/mount" >/dev/null
mounted=0

# Replace only this version/build's generated artifacts after all checks pass.
mv -f "$work/$release_name.dmg" ".build/releases/$release_name.dmg"
(
  cd .build/releases
  shasum -a 256 "$release_name.dmg" > "$release_name.dmg.sha256"
)
printf 'DMG: %s/.build/releases/%s.dmg\nSHA256: %s/.build/releases/%s.dmg.sha256\n' \
  "$PWD" "$release_name" "$PWD" "$release_name"
printf 'Local development build; not notarized. Nothing committed or uploaded.\n'
