#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 /absolute/path/OpenFish.app [--unsigned]" >&2
  exit 2
fi

APP_BUNDLE="$1"
SIGNATURE_MODE="${2:-signed}"
case "$APP_BUNDLE" in
  /*/OpenFish.app) ;;
  *) echo "check_openfish_release: expected an absolute OpenFish.app path" >&2; exit 2 ;;
esac
[[ -d "$APP_BUNDLE/Contents" ]] || { echo "check_openfish_release: app is absent" >&2; exit 1; }

if rg -n '/Users/[A-Za-z0-9._-]+/|file:///Users/[A-Za-z0-9._-]+/' "$APP_BUNDLE/Contents" >/dev/null; then
  echo "check_openfish_release: app contains a build-machine path" >&2
  exit 1
fi

escaped="$(find "$APP_BUNDLE" -type l -exec sh -c '
  root="$1"; shift
  for link do
    target="$(realpath "$link")"
    case "$target" in "$root"/*) ;; *) echo "$link -> $target" ;; esac
  done
' sh "$APP_BUNDLE" {} +)"
[[ -z "$escaped" ]] || { echo "check_openfish_release: external symlink(s):" >&2; echo "$escaped" >&2; exit 1; }

if [[ "$SIGNATURE_MODE" != "--unsigned" ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
fi
echo "OpenFish release checks passed"
