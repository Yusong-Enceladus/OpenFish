#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Release-blocking compatibility matrix. These tests intentionally use
# protocol fixtures and synthetic Packs rather than installed user Harnesses.
# A new ACP Harness therefore exercises the same boundary before any release
# artifact can be produced.
pnpm exec vitest run \
  packages/harness/harness/tests/manifest.spec.ts \
  packages/harness/harness/tests/service.spec.ts \
  packages/harness/harness-acp/tests/launch.spec.ts \
  packages/host/apiproxy/tests/api-proxy-agent-preset.spec.ts \
  packages/host/apiproxy/tests/api-proxy-models.spec.ts \
  packages/host/apiproxy/tests/api-proxy-workspace.spec.ts \
  packages/host/apiproxy/tests/fetch-carrier.spec.ts \
  packages/subagent/subagent-acp/tests/subagent-acp.spec.ts
