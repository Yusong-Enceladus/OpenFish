#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "usage: $0 [arm64|x86_64]" >&2; exit 2 ;; esac
MAC_BUNDLE_ID="${OPENFISH_MAC_BUNDLE_ID:-app.openfish.mac}"

BUILD_ROOT="$ROOT_DIR/.build/openfish-release-$ARCH"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Release/OpenFish.app"
OUTPUT_DIR="$ROOT_DIR/dist/openfish-$ARCH"
rm -rf "$BUILD_ROOT" "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

if [[ "${OPENFISH_SKIP_HARNESS_CONTRACT:-0}" != "1" ]]; then
  "$ROOT_DIR/script/check_harness_contract.sh"
fi
pnpm run build:lib:host
xcodebuild -project "$ROOT_DIR/apps/x-macos/XMac.xcodeproj" -scheme XMac -configuration Release \
  -derivedDataPath "$DERIVED_DATA" -destination "platform=macOS,arch=$ARCH" \
  PRODUCT_BUNDLE_IDENTIFIER="$MAC_BUNDLE_ID" CODE_SIGNING_ALLOWED=NO build
"$ROOT_DIR/script/package_openfish_host.sh" "$APP_BUNDLE" "$ARCH"
"$ROOT_DIR/script/smoke_openfish_bundle.sh" "$APP_BUNDLE" "$ARCH"

if [[ -n "${OPENFISH_DEVELOPER_ID_APPLICATION:-}" ]]; then
  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | rg -q 'Mach-O'; then
      codesign --force --options runtime --timestamp --sign "$OPENFISH_DEVELOPER_ID_APPLICATION" "$candidate"
    fi
  done < <(find "$APP_BUNDLE/Contents" -type f -print0)
  codesign --force --deep --options runtime --timestamp --sign "$OPENFISH_DEVELOPER_ID_APPLICATION" "$APP_BUNDLE"
  "$ROOT_DIR/script/check_openfish_release.sh" "$APP_BUNDLE"
else
  "$ROOT_DIR/script/check_openfish_release.sh" "$APP_BUNDLE" --unsigned
fi

hdiutil create -volname OpenFish -srcfolder "$APP_BUNDLE" -ov -format UDZO "$OUTPUT_DIR/OpenFish-$ARCH.dmg"

if [[ -n "${OPENFISH_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$OUTPUT_DIR/OpenFish-$ARCH.dmg" --keychain-profile "$OPENFISH_NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUTPUT_DIR/OpenFish-$ARCH.dmg"
  xcrun stapler validate "$OUTPUT_DIR/OpenFish-$ARCH.dmg"
fi

shasum -a 256 "$OUTPUT_DIR/OpenFish-$ARCH.dmg" > "$OUTPUT_DIR/OpenFish-$ARCH.sha256"

echo "$OUTPUT_DIR/OpenFish-$ARCH.dmg"
