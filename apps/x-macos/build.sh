#!/bin/bash
# Build the native macOS OpenFish client without opening Xcode.
# SwiftPM's sandbox manifest step is blocked in this build environment, so we
# compile the executable target directly with swiftc against the active SDK.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache .build/tmp
export TMPDIR="$PWD/.build/tmp"
SDK=$(xcrun --show-sdk-path)
swiftc -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -module-cache-path "$PWD/.build/module-cache" \
  -o "$PWD/.build/OpenFish" \
  Sources/XMac/*.swift
echo "built $PWD/.build/OpenFish"
