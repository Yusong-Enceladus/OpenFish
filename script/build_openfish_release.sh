#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENFISH_REPO_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/script/openfish_build_paths.sh"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "usage: $0 [arm64|x86_64]" >&2; exit 2 ;; esac
MAC_BUNDLE_ID="${OPENFISH_MAC_BUNDLE_ID:-app.openfish.mac}"

BUILD_ROOT="$OPENFISH_BUILD_ROOT/openfish-release-$ARCH"
DERIVED_DATA="$OPENFISH_DERIVED_DATA_ROOT/openfish-release-$ARCH"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Release/OpenFish.app"
OUTPUT_DIR="$OPENFISH_ARTIFACT_ROOT/openfish-$ARCH"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  # Remove an earlier build product before deleting its files, otherwise
  # Spotlight can retain a second OpenFish identity with no valid bundle.
  "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
fi
rm -rf "$BUILD_ROOT" "$DERIVED_DATA" "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

if [[ "${OPENFISH_SKIP_HARNESS_CONTRACT:-0}" != "1" ]]; then
  "$ROOT_DIR/script/check_harness_contract.sh"
fi
# The packaged Host imports several packages whose Node half is emitted during
# the client build face (notably dsh-client-connection). Building only the Host
# face can package a stale lib/index.js even while its fresh TypeScript source
# and declarations pass. Release artifacts must be assembled from both faces.
pnpm run build:lib
node "$ROOT_DIR/script/check_openfish_built_harness_runtime.mjs"
xcodebuild -project "$ROOT_DIR/apps/x-macos/XMac.xcodeproj" -scheme XMac -configuration Release \
  -derivedDataPath "$DERIVED_DATA" -destination "platform=macOS,arch=$ARCH" \
  PRODUCT_BUNDLE_IDENTIFIER="$MAC_BUNDLE_ID" CODE_SIGNING_ALLOWED=NO build
if [[ -x "$LSREGISTER" ]]; then
  # The release artifact is packaged into the DMG below; it is not an installed
  # application and must not remain discoverable beside ~/Applications/OpenFish.
  "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true

  XCODE_DERIVED_ROOT="/Users/$(id -un)/Library/Developer/Xcode/DerivedData"
  SEARCH_ROOTS=("$OPENFISH_BUILD_ROOT" "$OPENFISH_DERIVED_DATA_ROOT")
  [[ -d "$XCODE_DERIVED_ROOT" ]] && SEARCH_ROOTS+=("$XCODE_DERIVED_ROOT")
  while IFS= read -r candidate; do
    "$LSREGISTER" -u "$candidate" >/dev/null 2>&1 || true
  done < <(find "${SEARCH_ROOTS[@]}" -type d -name OpenFish.app -path '*/Build/Products/*' -prune -print 2>/dev/null)
fi
"$ROOT_DIR/script/package_openfish_host.sh" "$APP_BUNDLE" "$ARCH"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/OpenFish"
[[ -f "$APP_EXECUTABLE" ]] || { echo "release executable is missing: $APP_EXECUTABLE" >&2; exit 1; }
# Xcode's unsigned archive path retains Swift object/source paths in the Mach-O
# symbol table. Strip them before smoke, signing, notarization, and privacy scan.
strip -S -x "$APP_EXECUTABLE"
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

if [[ -x "$LSREGISTER" ]]; then
  # Packaging and smoke may cause LaunchServices to rediscover the release
  # product. It belongs inside the DMG, not in Spotlight beside the installed
  # application.
  "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
  INSTALLED_APP="/Users/$(id -un)/Applications/OpenFish.app"
  [[ -d "$INSTALLED_APP" ]] && "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true
fi

echo "$OUTPUT_DIR/OpenFish-$ARCH.dmg"
