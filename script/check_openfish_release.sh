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

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
short_version="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST" 2>/dev/null || true)"
build_version="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST" 2>/dev/null || true)"
[[ -n "$short_version" && -n "$build_version" ]] || {
  echo "check_openfish_release: app has no user-visible/build version" >&2
  exit 1
}

builder_user="$(id -un)"
if rg -a -n "/Users/${builder_user}/|file:///Users/${builder_user}/" "$APP_BUNDLE/Contents" >/dev/null; then
  echo "check_openfish_release: app contains a build-machine path" >&2
  exit 1
fi

if find "$APP_BUNDLE/Contents" -print \
  | sed "s#^$APP_BUNDLE/Contents##" \
  | rg -q "file[+]{3,}Users[+]${builder_user}[+]|(^|[+/])Users[+/]${builder_user}[+/]"; then
  echo "check_openfish_release: app contains a build-machine identity in a packaged path name" >&2
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
