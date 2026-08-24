#!/bin/bash
# Read-only smoke test: the native Swift client must talk to a running DSH
# host on 127.0.0.1:3080 through RPC plus both downlink WebSockets.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
OPENFISH_REPO_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/script/openfish_build_paths.sh"
cd "$ROOT_DIR/apps/x-macos"
TEST_BUILD_ROOT="$OPENFISH_BUILD_ROOT/tests/x-macos-api-smoke"
mkdir -p "$TEST_BUILD_ROOT/module-cache" "$TEST_BUILD_ROOT/tmp"
export TMPDIR="$TEST_BUILD_ROOT/tmp"
SDK=$(xcrun --show-sdk-path)
swiftc -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -module-cache-path "$TEST_BUILD_ROOT/module-cache" \
  Sources/XMac/NativeConnectionProfile.swift \
  Sources/XMac/XApiClient.swift Sources/XMac/DshLiveConnection.swift Tests/ApiSmoke.swift \
  -o "$TEST_BUILD_ROOT/opencodex-api-smoke"
"$TEST_BUILD_ROOT/opencodex-api-smoke"
