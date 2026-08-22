#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

privacy_report="$(mktemp "${TMPDIR:-/tmp}/openfish-privacy.XXXXXX")"
trap 'rm -f "$privacy_report"' EXIT
privacy_files=()
while IFS= read -r -d '' file; do
  case "$file" in
    dist/*|.build/*|*/.build/*|*/snapshots/*|*/fixtures/*|*/tests/*) continue ;;
  esac
  [[ -f "$file" ]] || continue
  privacy_files+=("$file")
done < <(git ls-files --cached --others --exclude-standard -z)

set +e
rg -n --with-filename --regexp '/Users/[A-Za-z0-9._-]+/|file:///Users/[A-Za-z0-9._-]+/' -- \
  "${privacy_files[@]}" >"$privacy_report"
privacy_status=$?
set -e
if [[ "$privacy_status" -gt 1 ]]; then
  echo "check_open_source_privacy: ripgrep failed while scanning source files" >&2
  exit "$privacy_status"
fi

if [[ -s "$privacy_report" ]]; then
  cat "$privacy_report" >&2
  echo "check_open_source_privacy: source files contain a developer-machine path" >&2
  exit 1
fi

# Reject the common credential formats most likely to be copied from a local
# developer setup.  Test snapshots and fixtures are intentionally outside this
# source-publication scan; committed product/demo material is not.
set +e
rg -n --with-filename --regexp \
  '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{36,}\b|\bsk-[A-Za-z0-9_-]{20,}\b|\bxox[baprs]-[A-Za-z0-9-]{20,}\b|Authorization:[[:space:]]*Bearer[[:space:]]+eyJ[A-Za-z0-9._-]+' \
  -- "${privacy_files[@]}" >"$privacy_report"
secret_status=$?
set -e
if [[ "$secret_status" -gt 1 ]]; then
  echo "check_open_source_privacy: ripgrep failed while scanning credential formats" >&2
  exit "$secret_status"
fi
if [[ -s "$privacy_report" ]]; then
  cat "$privacy_report" >&2
  echo "check_open_source_privacy: source files contain a credential-like value" >&2
  exit 1
fi

for generated in apps/x-cli/src/generated/config-keys.json apps/x-cli/src/generated/command-manifest.json apps/x-cli/src/generated/features.json; do
  jq -e '(.source | startswith("/") | not)' "$generated" >/dev/null
done

if jq -e '.keys[] | has("expected")' apps/x-cli/src/generated/config-keys.json >/dev/null; then
  echo "check_open_source_privacy: captured configuration values must not be committed" >&2
  exit 1
fi

echo "Open source privacy checks passed"
