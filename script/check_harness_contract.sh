#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENFISH_REPO_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/script/openfish_build_paths.sh"
cd "$ROOT_DIR"

# Release-blocking compatibility matrix. These tests intentionally use
# protocol fixtures and synthetic Packs rather than installed user Harnesses.
# A new ACP Harness therefore exercises the same boundary before any release
# artifact can be produced.
pnpm exec vitest run \
  packages/harness/harness/tests/manifest.spec.ts \
  packages/harness/harness/tests/conformance.spec.ts \
  packages/harness/harness/tests/projection.spec.ts \
  packages/harness/harness/tests/diagnostic.spec.ts \
  packages/harness/harness/tests/service.spec.ts \
  packages/harness/harness/tests/loader-composition.spec.ts \
  packages/harness/harness-acp/tests/launch.spec.ts \
  packages/harness/harness-acp/tests/acp-stream.spec.ts \
  packages/harness/harness-acp/tests/native-event.spec.ts \
  packages/harness/harness-acp/tests/codex-app-server.e2e.spec.ts \
  packages/harness/harness-acp/tests/unknown-acp.e2e.spec.ts \
  packages/api/harness-controller/tests/controller.spec.ts \
  packages/api/harness-controller/tests/community-github.spec.ts \
  packages/api/session-controller/tests/commands-create-fork.host.spec.ts \
  packages/api/session-controller/tests/session-models.host.spec.ts \
  packages/api/session-controller/tests/session-presets.host.spec.ts \
  packages/api/session-controller/tests/session-open-workspace-path.host.spec.ts \
  packages/api/session-controller/tests/session-list-blank.host.spec.ts \
  packages/bundle/x-native/tests/x-native.spec.ts \
  packages/subagent/subagent-acp/tests/subagent-acp.spec.ts
