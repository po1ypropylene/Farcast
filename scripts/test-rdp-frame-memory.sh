#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-support.sh rdp-frame-memory
cat > "$fixture_root/bridge.h" <<'HEADER'
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
BOOL FCCheckFrameMemory(BOOL regions, void (^consume)(NSData *, int, int));
NS_ASSUME_NONNULL_END
HEADER
xcrun clang -O2 -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 \
  -I Farcast/Native/RDP -I Vendor/Native/include -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
  -c Tests/Integration/RDP/frame_memory.m -o "$fixture_root/frame-memory.o"
compile_native_adapter "$fixture_root/support.o" "${rdp_support_sources[@]}"
xcrun swiftc -O -target arm64-apple-macos27.0 -parse-as-library \
  -import-objc-header "$fixture_root/bridge.h" \
  Farcast/Domain/RDPDisplayMode.swift Farcast/Domain/RDPDisplayLayout.swift \
  Farcast/Domain/RDPResizeCoordinator.swift Farcast/Protocols/RDP/RDPDesktopView.swift \
  Tests/Integration/RDP/frame_memory.swift "$fixture_root/frame-memory.o" "$fixture_root/support.o" \
  -L Vendor/Native/lib -Xlinker -rpath -Xlinker "$PWD/Vendor/Native/lib" \
  -lfreerdp3 -lfreerdp-client3 -lwinpr3 -lcrypto -o "$fixture_root/client"
"$fixture_root/client"
