#!/bin/bash
# Hermetic end-to-end validation of the native DSH client against the real
# composed Host, persistence, sandbox, approval, and tool stack. The model
# stream is a committed replay fixture, so this test uses no credential or
# external model request and leaves no session in the user's DSH home.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
OPENFISH_REPO_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/script/openfish_build_paths.sh"
cd "$ROOT_DIR/apps/x-macos"
TEST_BUILD_ROOT="$OPENFISH_BUILD_ROOT/tests/x-macos-behavior-smoke"
mkdir -p "$TEST_BUILD_ROOT/module-cache" "$TEST_BUILD_ROOT/tmp"
export TMPDIR="$TEST_BUILD_ROOT/tmp"
SDK=$(xcrun --show-sdk-path)
swiftc -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -module-cache-path "$TEST_BUILD_ROOT/module-cache" \
  -o "$TEST_BUILD_ROOT/opencodex-behavior-smoke" \
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
  Tests/BehaviorSmoke.swift

cd "$ROOT_DIR"
if [[ ! -f "$ROOT_DIR/apps/web/dist/index.html" ]]; then
  pnpm run build:web
fi
OPENCODEX_BEHAVIOR_BINARY="$TEST_BUILD_ROOT/opencodex-behavior-smoke" \
  pnpm vitest run apps/web/tests/opencodex-native-behavior.spec.ts
