#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-simulator}"
OPENFISH_REPO_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/script/openfish_build_paths.sh"
BUILD_ROOT="$OPENFISH_BUILD_ROOT/opencodex-ios"
DERIVED_DATA="$OPENFISH_DERIVED_DATA_ROOT/opencodex-ios"
PROJECT="$ROOT_DIR/apps/x-ios/OpenCodexIOS.xcodeproj"
SCHEME="OpenFishIOS"
BUNDLE_ID="${OPENFISH_IOS_BUNDLE_ID:-app.openfish.ios}"
DEVICE_ID="${OPENCODEX_IOS_DEVICE_ID:-}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

unregister_ios_build_product() {
  local app_bundle="$1"
  [[ -x "$LSREGISTER" ]] || return 0
  # Xcode registers simulator/device products with macOS LaunchServices even
  # though they are not runnable Mac apps. Remove only that build-product
  # record so Spotlight exposes the installed Mac OpenFish exactly once.
  "$LSREGISTER" -u "$app_bundle" >/dev/null 2>&1 || true
}

mkdir -p "$BUILD_ROOT"

case "$MODE" in
  simulator|--simulator|device|--device) ;;
  *)
    echo "usage: $0 [simulator|--device]" >&2
    exit 2
    ;;
esac

if [[ "$MODE" == "simulator" || "$MODE" == "--simulator" ]]; then
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_DATA" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGNING_ALLOWED=NO \
    build

  xcrun simctl bootstatus booted -b >/dev/null 2>&1 || open -a Simulator
  xcrun simctl bootstatus booted -b
  SIMULATOR_APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/OpenFish.app"
  xcrun simctl install booted "$SIMULATOR_APP"
  unregister_ios_build_product "$SIMULATOR_APP"
  xcrun simctl launch booted "$BUNDLE_ID"
  exit
fi

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_TMP="$(mktemp -d "$OPENFISH_TEMP_ROOT/opencodex-ios-device.XXXXXX")"
  trap 'rm -rf "$DEVICE_TMP"' EXIT
  DEVICE_JSON="$DEVICE_TMP/devices.json"
  xcrun devicectl list devices --quiet --json-output "$DEVICE_JSON"
  DEVICE_ID="$(DEVICE_JSON="$DEVICE_JSON" node --input-type=module - <<'NODE'
import { readFileSync } from 'node:fs'
const devices = JSON.parse(readFileSync(process.env.DEVICE_JSON, 'utf8')).result?.devices ?? []
const phones = devices.filter(device =>
  String(device.hardwareProperties?.marketingName ?? device.deviceProperties?.name ?? '')
    .toLowerCase().includes('iphone')
  && (device.connectionProperties?.transportType || device.connectionProperties?.tunnelState === 'connected'))
if (phones.length !== 1 || !phones[0]?.identifier) process.exit(1)
process.stdout.write(phones[0].identifier)
NODE
)" || {
    echo "Connect exactly one paired iPhone, or set OPENCODEX_IOS_DEVICE_ID." >&2
    exit 1
  }
fi

SIGNING_ARGS=(-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic)
DEVELOPMENT_TEAM="${OPENCODEX_DEVELOPMENT_TEAM:-}"
if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  # The parenthesized suffix in an Apple Development identity's display name
  # is the certificate identifier, not necessarily its signing Team ID. The
  # authoritative Team ID is the certificate subject's OU field.
  CERTIFICATE_SUBJECTS="$(
    security find-certificate -a -c 'Apple Development' -p 2>/dev/null \
      | openssl crl2pkcs7 -nocrl -certfile /dev/stdin 2>/dev/null \
      | openssl pkcs7 -print_certs -noout 2>/dev/null \
      || true
  )"
  DEVELOPMENT_TEAM="$(CERTIFICATE_SUBJECTS="$CERTIFICATE_SUBJECTS" node --input-type=module - <<'NODE'
const matches = [...(process.env.CERTIFICATE_SUBJECTS ?? '').matchAll(/\bOU\s*=\s*([A-Z0-9]{10})\b/g)]
const teams = [...new Set(matches.map(match => match[1]))]
if (teams.length === 1) process.stdout.write(teams[0])
NODE
)"
fi
if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  SIGNING_ARGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  "${SIGNING_ARGS[@]}" \
  build

xcrun devicectl device install app \
  --device "$DEVICE_ID" \
  "$DERIVED_DATA/Build/Products/Debug-iphoneos/OpenFish.app"
unregister_ios_build_product "$DERIVED_DATA/Build/Products/Debug-iphoneos/OpenFish.app"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
