#!/bin/bash
# Build the native OpenFish iPhone app for the iOS simulator without opening Xcode.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
xcodebuild \
  -project OpenCodexIOS.xcodeproj \
  -scheme OpenFishIOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$PWD/.build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build
echo "built $PWD/.build/DerivedData/Build/Products/Debug-iphonesimulator/OpenFish.app"
