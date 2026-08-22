#!/bin/bash
# Hermetic end-to-end validation of the native DSH client against the real
# composed Host, persistence, sandbox, approval, and tool stack. The model
# stream is a committed replay fixture, so this test uses no credential or
# external model request and leaves no session in the user's DSH home.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/tmp
export TMPDIR="$PWD/.build/tmp"
SDK=$(xcrun --show-sdk-path)
swiftc -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -module-cache-path "$PWD/.build/module-cache" \
  -o "$PWD/.build/opencodex-behavior-smoke" \
  Sources/XMac/XApiClient.swift \
  Sources/XMac/DshLiveConnection.swift \
  Sources/XMac/ConversationProjection.swift \
  Sources/XMac/LocalNotificationService.swift \
  Sources/XMac/LocalVoiceService.swift \
  Sources/XMac/MacProjectionCache.swift \
  Sources/XMac/NativeConnectionProfile.swift \
  Sources/XMac/OpenCodexStore.swift \
  Sources/XMac/XNativeClient.swift \
  Sources/XMac/IdleGuard.swift \
  Tests/BehaviorSmoke.swift

cd ../..
OPENCODEX_BEHAVIOR_BINARY="$PWD/apps/x-macos/.build/opencodex-behavior-smoke" \
  pnpm vitest run apps/web/tests/opencodex-native-behavior.spec.ts
