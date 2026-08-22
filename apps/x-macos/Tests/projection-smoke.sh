#!/bin/bash
# Deterministic, offline validation of the native presentation projection over
# DSH's merge-extensible event envelopes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/tmp
export TMPDIR="$PWD/.build/tmp"
SDK=$(xcrun --show-sdk-path)
swiftc -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -module-cache-path "$PWD/.build/module-cache" \
  Sources/XMac/XApiClient.swift Sources/XMac/ConversationProjection.swift Tests/ProjectionSmoke.swift \
  -o "$PWD/.build/projection-smoke"
"$PWD/.build/projection-smoke"
