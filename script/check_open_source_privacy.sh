#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

privacy_report="$(mktemp "${TMPDIR:-/tmp}/openfish-privacy.XXXXXX")"
trap 'rm -f "$privacy_report"' EXIT
privacy_files=()
identity_files=()
while IFS= read -r -d '' file; do
  case "$file" in
    dist/*|.build/*|*/.build/*) continue ;;
  esac
  [[ -f "$file" ]] || continue
  identity_files+=("$file")
  case "$file" in
    */snapshots/*|*/fixtures/*|*/tests/*) continue ;;
  esac
  privacy_files+=("$file")
done < <(git ls-files --cached --others --exclude-standard -z)

# Test fixtures may intentionally contain synthetic home paths and token-shaped
# values. They still must not contain this workstation's actual account or Host
# identity. Match exact local identities across every publishable file and
# report only filenames, never the private value itself.
local_account="$(id -un)"
local_host="$(hostname -s)"
set +e
rg --fixed-strings --files-with-matches \
  --regexp "/Users/$local_account/" \
  --regexp "file:///Users/$local_account/" \
  --regexp "$local_account@" \
  --regexp "$local_host.local" \
  -- "${identity_files[@]}" >"$privacy_report"
identity_status=$?
set -e
if [[ "$identity_status" -gt 1 ]]; then
  echo "check_open_source_privacy: ripgrep failed while scanning local workstation identity" >&2
  exit "$identity_status"
fi
if [[ -s "$privacy_report" ]]; then
  sort -u "$privacy_report" >&2
  echo "check_open_source_privacy: publishable files contain this workstation's identity" >&2
  exit 1
fi

set +e
rg --files-with-matches --regexp '/Users/[A-Za-z0-9._-]+/|file:///Users/[A-Za-z0-9._-]+/' -- \
  "${privacy_files[@]}" >"$privacy_report"
privacy_status=$?
set -e
if [[ "$privacy_status" -gt 1 ]]; then
  echo "check_open_source_privacy: ripgrep failed while scanning source files" >&2
  exit "$privacy_status"
fi

if [[ -s "$privacy_report" ]]; then
  sort -u "$privacy_report" >&2
  echo "check_open_source_privacy: source files contain a developer-machine path" >&2
  exit 1
fi

# Reject the common credential formats most likely to be copied from a local
# developer setup.  Test snapshots and fixtures are intentionally outside this
# source-publication scan; committed product/demo material is not.
set +e
rg --files-with-matches --regexp \
  '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{36,}\b|\bsk-[A-Za-z0-9_-]{20,}\b|\bxox[baprs]-[A-Za-z0-9-]{20,}\b|Authorization:[[:space:]]*Bearer[[:space:]]+eyJ[A-Za-z0-9._-]+' \
  -- "${privacy_files[@]}" >"$privacy_report"
secret_status=$?
set -e
if [[ "$secret_status" -gt 1 ]]; then
  echo "check_open_source_privacy: ripgrep failed while scanning credential formats" >&2
  exit "$secret_status"
fi
if [[ -s "$privacy_report" ]]; then
  sort -u "$privacy_report" >&2
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

# Public screenshots and icons are source artifacts too. This check inspects
# their container metadata and uncompressed strings without echoing possible
# private values into CI logs. OCR is enforced separately on macOS, where the
# native Vision framework is available.
node script/check_openfish_public_assets.mjs

echo "Open source privacy checks passed"
