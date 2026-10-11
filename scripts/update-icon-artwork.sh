#!/bin/bash
# Regenerate supplied SVG artwork while preserving Icon Composer's material settings.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/icon-artwork
CLANG_MODULE_CACHE_PATH="$PWD/.dependencies/clang-module-cache" \
  SWIFT_MODULECACHE_PATH="$PWD/.dependencies/swift-module-cache" \
  xcrun swift scripts/generate-icon.swift .build/icon-artwork
for layer in Background Stand Monitor Broadcast; do
  cp ".build/icon-artwork/$layer.png" "Farcast/AppIcon.icon/Assets/$layer.png"
done
mkdir -p Farcast/Assets.xcassets/BrandMark.imageset
cp .build/icon-artwork/BrandMark.png Farcast/Assets.xcassets/BrandMark.imageset/BrandMark.png
cat > Farcast/Assets.xcassets/BrandMark.imageset/Contents.json <<'JSON'
{
  "images": [{ "filename": "BrandMark.png", "idiom": "universal" }],
  "info": { "author": "xcode", "version": 1 },
  "properties": { "template-rendering-intent": "template" }
}
JSON
