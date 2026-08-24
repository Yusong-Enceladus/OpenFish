#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ALLOW_DIRTY=0
if [[ "${1:-}" == "--allow-dirty" && $# -eq 1 ]]; then
  ALLOW_DIRTY=1
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--allow-dirty]" >&2
  exit 2
fi

required=(
  .github/workflows/openfish-release.yml
  .github/ISSUE_TEMPLATE/openfish-bug.md
  SECURITY.md
  SECURITY.zh.md
  README.md
  README.zh.md
  docs/openfish-compatibility.md
  docs/openfish-compatibility.zh.md
  docs/openfish-demo-mode.md
  docs/openfish-demo-mode.zh.md
  docs/openfish-public-alpha.md
  docs/openfish-public-alpha.zh.md
  docs/openfish-threat-model.md
  docs/openfish-threat-model.zh.md
  docs/openfish-value-evidence.md
  docs/openfish-value-evidence.zh.md
  docs/harness-driver-sdk.md
  docs/harness-driver-sdk.zh.md
  docs/publishing-harness-packs.md
  docs/publishing-harness-packs.zh.md
  community/harnesses/index.json
  community/harnesses/revocations.json
  apps/x-macos/Sources/XMac/Resources/openfish-demo-harnesses.json
  apps/x-ios/Sources/XiOS/Resources/openfish-demo-harnesses.json
  script/build_openfish_release.sh
  script/check_openfish_built_harness_runtime.mjs
  script/check_harness_contract.sh
  script/check_openfish_git_history_privacy.sh
  script/check_open_source_privacy.sh
  script/check_openfish_public_assets.mjs
  script/check_openfish_public_assets_ocr.swift
  packages/harness/harness/package.json
  packages/harness/harness-acp/package.json
  apps/x-macos/XMac.xcodeproj/project.pbxproj
  apps/x-ios/OpenCodexIOS.xcodeproj/project.pbxproj
)

for file in "${required[@]}"; do
  [[ -f "$file" ]] || {
    echo "check_openfish_source_release: required source file is missing: $file" >&2
    exit 1
  }
done

[[ "$(sed -n '1p' README.md)" == "# OpenFish" ]] || {
  echo "check_openfish_source_release: README must identify the repository as OpenFish" >&2
  exit 1
}

rg -q 'check_openfish_source_release\.sh' .github/workflows/openfish-release.yml || {
  echo "check_openfish_source_release: release workflow does not enforce this preflight" >&2
  exit 1
}
rg -q 'check_openfish_public_assets_ocr\.swift' .github/workflows/openfish-release.yml || {
  echo "check_openfish_source_release: release workflow does not enforce screenshot OCR review" >&2
  exit 1
}
rg -q 'check_harness_contract\.sh' script/build_openfish_release.sh || {
  echo "check_openfish_source_release: macOS release build does not enforce the Harness contract" >&2
  exit 1
}
if rg -q 'PRODUCT_BUNDLE_IDENTIFIER = ai\.deepseek\.opencodex' \
  apps/x-macos/XMac.xcodeproj/project.pbxproj apps/x-ios/OpenCodexIOS.xcodeproj/project.pbxproj; then
  echo "check_openfish_source_release: release projects still use the upstream DSH bundle namespace" >&2
  exit 1
fi

./script/check_open_source_privacy.sh
./script/check_openfish_git_history_privacy.sh
pnpm run verify-openfish-community-catalog
pnpm run verify-openfish-demo-harness-catalog

if [[ "$ALLOW_DIRTY" -eq 0 ]]; then
  dirty="$(git status --short)"
  if [[ -n "$dirty" ]]; then
    printf '%s\n' "$dirty" >&2
    echo "check_openfish_source_release: source tree is dirty; commit every intended release file first" >&2
    exit 1
  fi
fi

echo "OpenFish source release preflight passed"
