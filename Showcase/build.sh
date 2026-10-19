#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
signing_identity="$(python3 scripts/local-signing.py select)"
[[ "$signing_identity" != - ]] || { echo 'Showcase builds require the pinned development certificate.' >&2; exit 1; }
# Reuse the standard dependency preparation and signing policy.
[[ -f Vendor/Native/lib/libssh2.1.dylib && -f Vendor/Native/lib/libfreerdp3.3.dylib && "$(cat Vendor/Native/.platform 2>/dev/null)" == arm64-macos27-audio1 && "$(cat Vendor/Native/.build-inputs 2>/dev/null)" == "$(shasum -a 256 scripts/prepare-dependencies.sh)" ]] || scripts/prepare-dependencies.sh
scripts/prepare-wireguard.sh
# Every new compilation advances the shared build number, retaining the version.
python3 scripts/advance-build-number.py
python3 Showcase/prepare.py
rm -rf .build/Showcase/Build/Products/Release/Farcast.app
xcodebuild -project .build/showcase-source/Farcast.xcodeproj -scheme Farcast -configuration Release \
    -derivedDataPath .build/Showcase -clonedSourcePackagesDirPath .dependencies/swift-packages \
    -skipPackagePluginValidation CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$signing_identity" \
    ENABLE_HARDENED_RUNTIME=NO build
python3 Showcase/verify.py .build/Showcase/Build/Products/Release/Farcast.app
mkdir -p .build/Xcode/Build/Products/Release
rm -rf .build/Xcode/Build/Products/Release/Farcast-demo.app
mv .build/Showcase/Build/Products/Release/Farcast.app .build/Xcode/Build/Products/Release/Farcast-demo.app
printf 'Built app: %s/.build/Xcode/Build/Products/Release/Farcast-demo.app\n' "$PWD"
