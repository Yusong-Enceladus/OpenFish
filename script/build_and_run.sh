#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="OpenFish"
BUNDLE_ID="${OPENFISH_MAC_BUNDLE_ID:-app.openfish.mac}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$ROOT_DIR/.build/opencodex"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
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
rm -rf "$INSTALLED_APP"
mkdir -p "$USER_APPLICATIONS"
mv "$APP_BUNDLE" "$INSTALLED_APP"

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
