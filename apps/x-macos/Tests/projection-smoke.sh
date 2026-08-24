#!/bin/bash
# Deterministic, offline validation of the native presentation projection over
# DSH's merge-extensible event envelopes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
OPENFISH_REPO_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/script/openfish_build_paths.sh"
cd "$ROOT_DIR/apps/x-macos"
TEST_BUILD_ROOT="$OPENFISH_BUILD_ROOT/tests/x-macos-projection-smoke"
mkdir -p "$TEST_BUILD_ROOT/module-cache" "$TEST_BUILD_ROOT/tmp"
export TMPDIR="$TEST_BUILD_ROOT/tmp"
SDK=$(xcrun --show-sdk-path)
swiftc -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -module-cache-path "$TEST_BUILD_ROOT/module-cache" \
  Sources/XMac/NativeConnectionProfile.swift \
  Sources/XMac/XApiClient.swift Sources/XMac/ConversationProjection.swift Tests/ProjectionSmoke.swift \
  -o "$TEST_BUILD_ROOT/projection-smoke"
"$TEST_BUILD_ROOT/projection-smoke"
