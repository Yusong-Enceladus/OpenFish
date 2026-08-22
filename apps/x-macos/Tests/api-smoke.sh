#!/bin/bash
# Read-only smoke test: the native Swift client must talk to a running DSH
# host on 127.0.0.1:3080 through RPC plus both downlink WebSockets.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/tmp
export TMPDIR="$PWD/.build/tmp"
SDK=$(xcrun --show-sdk-path)
swiftc -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -module-cache-path "$PWD/.build/module-cache" \
  Sources/XMac/XApiClient.swift Sources/XMac/DshLiveConnection.swift Tests/ApiSmoke.swift \
  -o "$PWD/.build/opencodex-api-smoke"
"$PWD/.build/opencodex-api-smoke"
