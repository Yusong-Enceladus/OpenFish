#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="OpenFish"
BUNDLE_ID="${OPENFISH_MAC_BUNDLE_ID:-app.openfish.mac}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENFISH_REPO_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/script/openfish_build_paths.sh"
BUILD_ROOT="$OPENFISH_BUILD_ROOT/opencodex-macos"
DERIVED_DATA="$OPENFISH_DERIVED_DATA_ROOT/opencodex-macos"
HOST_LOG="$BUILD_ROOT/host.log"
HOST_ERROR_LOG="$BUILD_ROOT/host-error.log"
HOST_SERVICE="$BUNDLE_ID.host"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
USER_APPLICATIONS="$(osascript -e 'POSIX path of (path to applications folder from user domain)')"
INSTALLED_APP="${USER_APPLICATIONS%/}/$APP_NAME.app"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

mkdir -p "$BUILD_ROOT"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x OpenCodex >/dev/null 2>&1 || true

pnpm run build:lib:host
node "$ROOT_DIR/script/check_openfish_built_harness_runtime.mjs"

xcodebuild \
  -project "$ROOT_DIR/apps/x-macos/XMac.xcodeproj" \
  -scheme XMac \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "OpenFish app bundle was not produced at $APP_BUNDLE" >&2
  exit 1
fi

"$ROOT_DIR/script/package_openfish_host.sh" "$APP_BUNDLE"

# Exercise the same self-contained bundle users receive. An obsolete
# source-checkout Host must never make a new UI bind to an old runtime.
launchctl remove "$HOST_SERVICE" >/dev/null 2>&1 || true
EXPECTED_INSTALLED_APP="${USER_APPLICATIONS%/}/$APP_NAME.app"
if [[ "$INSTALLED_APP" != "$EXPECTED_INSTALLED_APP" ]]; then
  echo "Refusing unexpected install destination: $INSTALLED_APP" >&2
  exit 1
fi
# Remove the exact previous bundle from Launch Services before replacing it.
# This matters when upgrading from the historical ai.deepseek.opencodex id:
# otherwise Spotlight can keep both identities for one on-disk application.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
unregister_transient_openfish_records() {
  [[ -x "$LSREGISTER" ]] || return 0

  # LaunchServices keeps records for build products after DerivedData has been
  # deleted, so `find` alone cannot remove every duplicate Spotlight result.
  # Only unregister OpenFish build products; never touch an installed app.
  while IFS= read -r candidate; do
    [[ -z "$candidate" || "$candidate" == "$INSTALLED_APP" ]] && continue
    "$LSREGISTER" -u "$candidate" >/dev/null 2>&1 || true
  done < <(
    "$LSREGISTER" -dump 2>/dev/null \
      | awk '
          /^path:[[:space:]]/ {
            path = $0
            sub(/^path:[[:space:]]*/, "", path)
            sub(/ \(0x[[:xdigit:]]+\)$/, "", path)
            if (index(path, "/Build/Products/") > 0 && path ~ /\/OpenFish[.]app$/) print path
          }
        ' \
      | sort -u
  )
}

unregister_transient_openfish_records
if [[ -d "$INSTALLED_APP" && -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$INSTALLED_APP" >/dev/null 2>&1 || true
fi
if [[ -x "$LSREGISTER" ]]; then
  # xcodebuild registers its DerivedData product before this script moves it.
  # Remove that transient identity so Spotlight/Dock expose only the installed
  # bundle in ~/Applications after repeated development installs.
  "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
fi
rm -rf "$INSTALLED_APP"
mkdir -p "$USER_APPLICATIONS"
mv "$APP_BUNDLE" "$INSTALLED_APP"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true

  # Xcode and screenshot builds can be indexed directly from DerivedData even
  # after LaunchServices unregisters them. Remove only generated macOS
  # OpenFish.app products after installation so Spotlight has one identity.
  XCODE_DERIVED_ROOT="/Users/$(id -un)/Library/Developer/Xcode/DerivedData"
  SEARCH_ROOTS=("$OPENFISH_BUILD_ROOT" "$OPENFISH_DERIVED_DATA_ROOT")
  [[ -d "$XCODE_DERIVED_ROOT" ]] && SEARCH_ROOTS+=("$XCODE_DERIVED_ROOT")
  while IFS= read -r candidate; do
    [[ "$candidate" == "$INSTALLED_APP" ]] && continue
    info="$candidate/Contents/Info.plist"
    [[ -f "$info" ]] || continue
    # iPhone build products share the filename. LSMinimumSystemVersion is the
    # macOS-only admission fact that prevents deleting a phone build here.
    if ! /usr/bin/plutil -extract LSMinimumSystemVersion raw "$info" >/dev/null 2>&1; then
      continue
    fi
    "$LSREGISTER" -u "$candidate" >/dev/null 2>&1 || true
    rm -rf -- "$candidate"
  done < <(find "${SEARCH_ROOTS[@]}" -type d -name "$APP_NAME.app" -path '*/Build/Products/*' -prune -print 2>/dev/null)
  unregister_transient_openfish_records
  "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true
fi

open_app() {
  /usr/bin/open -n "$INSTALLED_APP"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALLED_APP/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _attempt in {1..60}; do
      if curl --fail --silent --max-time 1 "http://127.0.0.1:3080/x-native/v2/health" \
        | "$INSTALLED_APP/Contents/Resources/OpenFishHostRuntime/node/bin/node" -e '
          let input=""; process.stdin.on("data", c => input += c); process.stdin.on("end", () => {
            const h=JSON.parse(input); process.exit(h.ok && h.embeddedRuntimeId ? 0 : 1)
          })
        '; then
        pgrep -x "$APP_NAME" >/dev/null
        exit 0
      fi
      sleep 0.25
    done
    echo "OpenFish did not start its embedded Host" >&2
    exit 1
    ;;
esac
