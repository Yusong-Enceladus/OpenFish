#!/bin/bash
# Build the native OpenFish iPhone module for the iOS simulator without opening Xcode.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache .build/tmp
export TMPDIR="$PWD/.build/tmp"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swiftc -parse-as-library \
  -target arm64-apple-ios17.0-simulator \
  -sdk "$SDK" \
  -module-cache-path "$PWD/.build/module-cache" \
  -emit-library \
  -o "$PWD/.build/libXIOS.dylib" \
  Sources/XiOS/*.swift
echo "built $PWD/.build/libXIOS.dylib (OpenFish iOS module)"
