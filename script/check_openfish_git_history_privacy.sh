#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

report="$(mktemp "${TMPDIR:-/tmp}/openfish-history.XXXXXX")"
trap 'rm -f "$report"' EXIT

# Public releases use a GitHub no-reply identity so a workstation hostname or
# private mailbox cannot become immutable commit metadata. Additional public
# addresses can be named explicitly by a release owner when required.
allowed_extra=",${OPENFISH_ALLOWED_RELEASE_EMAILS:-},"
while IFS=$'\t' read -r commit author committer; do
  for email in "$author" "$committer"; do
    if [[ "$email" == *"@users.noreply.github.com" ]]; then
      continue
    fi
    if [[ "$allowed_extra" == *",$email,"* && -n "$email" ]]; then
      continue
    fi
    printf '%s\tcommit identity is not an approved public address\n' "$commit" >>"$report"
    break
  done
done < <(git log --format=$'%H\t%ae\t%ce' HEAD)

# Messages are public metadata too. Do not echo a match into logs.
if git log --format='%H%n%s%n%b' HEAD | rg -q '/Users/[A-Za-z0-9._-]+/|file:///Users/|[A-Za-z0-9._-]+\.local\b'; then
  printf 'history\tcommit message contains workstation metadata\n' >>"$report"
fi

if [[ -s "$report" ]]; then
  sort -u "$report" >&2
  echo "check_openfish_git_history_privacy: publish from a sanitized OpenFish branch" >&2
  exit 1
fi

echo "OpenFish Git history identity checks passed"
