#!/bin/bash
# Render deterministic native UI fixtures without opening an application window.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/tmp .build/visual-smoke
export TMPDIR="$PWD/.build/tmp"
SDK=$(xcrun --show-sdk-path)
swiftc -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -module-cache-path "$PWD/.build/module-cache" \
  -o "$PWD/.build/visual-smoke-runner" \
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
  Sources/XMac/InAppBrowserView.swift \
  Sources/XMac/ContentView.swift \
  Tests/VisualSmoke.swift
"$PWD/.build/visual-smoke-runner" "$PWD/.build/visual-smoke"
