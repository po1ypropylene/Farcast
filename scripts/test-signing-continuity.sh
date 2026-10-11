#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh signing-continuity
signing_identity="$(python3 scripts/local-signing.py select)"
[[ "$signing_identity" != - ]] || { echo 'This test requires certificate signing.' >&2; exit 2; }
for revision in 1 2; do
    xcrun clang -fobjc-arc -Wno-deprecated-declarations -mmacosx-version-min=27.0 \
      -DCONTENT_REVISION="$revision" -framework Foundation -framework Security \
      Tests/Integration/Workspace/SigningChecks.m -o "$fixture_root/revision-$revision"
    codesign --force --sign "$signing_identity" --identifier com.peterpo.farcast.signing-fixture \
      --timestamp=none "$fixture_root/revision-$revision" >/dev/null 2>&1
    codesign -d -r- "$fixture_root/revision-$revision" 2>&1 | sed -n 's/^designated => //p' > "$fixture_root/requirement-$revision"
    codesign -dv --verbose=4 "$fixture_root/revision-$revision" 2>&1 | sed -n 's/^CDHash=//p' > "$fixture_root/hash-$revision"
done
cmp "$fixture_root/requirement-1" "$fixture_root/requirement-2"
if cmp -s "$fixture_root/hash-1" "$fixture_root/hash-2"; then echo 'FAIL test binaries did not change.' >&2; exit 1; fi
codesign --verify --strict -R "=$(cat "$fixture_root/requirement-1")" "$fixture_root/revision-2"
echo 'PASS changed binaries satisfy the same certificate-backed requirement.'
"$fixture_root/revision-1" create "$fixture_root/owned.keychain-db"
"$fixture_root/revision-2" read "$fixture_root/owned.keychain-db"
