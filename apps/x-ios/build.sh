#!/bin/bash
# Build the native OpenFish iPhone app for the iOS simulator without opening Xcode.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OPENFISH_REPO_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/script/openfish_build_paths.sh"
cd "$ROOT_DIR/apps/x-ios"
DERIVED_DATA="$OPENFISH_DERIVED_DATA_ROOT/x-ios-simulator"
mkdir -p "$DERIVED_DATA"
xcodebuild \
  -project OpenCodexIOS.xcodeproj \
  -scheme OpenFishIOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/OpenFish.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
fi
echo "built $APP_BUNDLE"
