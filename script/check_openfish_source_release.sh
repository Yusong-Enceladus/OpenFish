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
  README.md
  docs/openfish-compatibility.md
  docs/openfish-public-alpha.md
  script/build_openfish_release.sh
  script/check_harness_contract.sh
  script/check_open_source_privacy.sh
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

if [[ "$ALLOW_DIRTY" -eq 0 ]]; then
  dirty="$(git status --short)"
  if [[ -n "$dirty" ]]; then
    printf '%s\n' "$dirty" >&2
    echo "check_openfish_source_release: source tree is dirty; commit every intended release file first" >&2
    exit 1
  fi
fi

echo "OpenFish source release preflight passed"
