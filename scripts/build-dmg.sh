#!/bin/bash
# Build a local release and package only the verified app and installation shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == --help && $# == 1 ]]; then
  printf 'Usage: scripts/build-dmg.sh\nEdit Version.xcconfig first. Outputs a verified DMG and SHA256 file in .build/releases.\nLocal builds are ad-hoc signed and not notarized. Nothing is committed or uploaded.\n'
  exit 0
fi
if [[ $# != 0 ]]; then
  printf 'Usage: scripts/build-dmg.sh [--help]\n' >&2
  exit 1
fi

scripts/build.sh
app="$PWD/.build/Xcode/Build/Products/Release/Farcast.app"
# Derive the filename from the actual bundle, never from a second version source.
release_name=$(python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib
import re
import sys

with open(sys.argv[1], 'rb') as file:
    info = plistlib.load(file)
version = info['CFBundleShortVersionString']
build = info['CFBundleVersion']
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[1-9][0-9]*', build):
    raise SystemExit('Set a major.minor.patch version and a positive integer build in Version.xcconfig.')
print(f'Farcast-{version}-build-{build}-arm64')
PY
)

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
ln -s /Applications "$work/payload/Applications"
diskutil image create from --volumeName "Farcast" --format UDZO \
  "$work/payload" "$work/$release_name.dmg"
hdiutil verify "$work/$release_name.dmg"
diskutil image attach --readOnly --nobrowse --mountPoint "$work/mount" "$work/$release_name.dmg" >/dev/null
mounted=1
python3 scripts/verify-bundle.py "$work/mount/Farcast.app"
python3 scripts/local-signing.py verify "$work/mount/Farcast.app"
cmp CHANGELOG.md "$work/mount/CHANGELOG.md"
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
