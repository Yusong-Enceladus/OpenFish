#!/bin/bash
# Build the native macOS OpenFish client without opening Xcode.
# SwiftPM's sandbox manifest step is blocked in this build environment, so we
# compile the executable target directly with swiftc against the active SDK.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OPENFISH_REPO_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/script/openfish_build_paths.sh"
cd "$ROOT_DIR/apps/x-macos"
APP_BUILD_ROOT="$OPENFISH_BUILD_ROOT/apps/x-macos-direct"
mkdir -p "$APP_BUILD_ROOT/module-cache" "$APP_BUILD_ROOT/tmp"
export TMPDIR="$APP_BUILD_ROOT/tmp"
SDK=$(xcrun --show-sdk-path)
swiftc -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -module-cache-path "$APP_BUILD_ROOT/module-cache" \
  -o "$APP_BUILD_ROOT/OpenFish" \
  Sources/XMac/*.swift
echo "built $APP_BUILD_ROOT/OpenFish"
