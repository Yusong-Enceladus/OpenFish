#!/bin/bash
# Render deterministic native UI fixtures without opening an application window.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
OPENFISH_REPO_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/script/openfish_build_paths.sh"
cd "$ROOT_DIR/apps/x-macos"
TEST_BUILD_ROOT="$OPENFISH_BUILD_ROOT/tests/x-macos-visual-smoke"
mkdir -p "$TEST_BUILD_ROOT/module-cache" "$TEST_BUILD_ROOT/tmp" "$TEST_BUILD_ROOT/output"
export TMPDIR="$TEST_BUILD_ROOT/tmp"
SDK=$(xcrun --show-sdk-path)
swiftc -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -module-cache-path "$TEST_BUILD_ROOT/module-cache" \
  -o "$TEST_BUILD_ROOT/visual-smoke-runner" \
  Sources/XMac/XApiClient.swift \
  Sources/XMac/DshLiveConnection.swift \
  Sources/XMac/ConversationProjection.swift \
  Sources/XMac/LocalNotificationService.swift \
  Sources/XMac/LocalVoiceService.swift \
  Sources/XMac/MacProjectionCache.swift \
  Sources/XMac/NativeConnectionProfile.swift \
  Sources/XMac/OpenFishHostRuntime.swift \
  Sources/XMac/OpenCodexStore.swift \
  Sources/XMac/XNativeClient.swift \
  Sources/XMac/IdleGuard.swift \
  Sources/XMac/InAppBrowserView.swift \
  Sources/XMac/ContentView.swift \
  Tests/VisualSmoke.swift
cp Sources/XMac/Resources/openfish-demo-harnesses.json "$TEST_BUILD_ROOT/openfish-demo-harnesses.json"
"$TEST_BUILD_ROOT/visual-smoke-runner" "$TEST_BUILD_ROOT/output"
