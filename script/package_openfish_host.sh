#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 /absolute/path/OpenFish.app [arm64|x86_64]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$1"
case "$APP_BUNDLE" in
  /*/OpenFish.app) ;;
  *) echo "package_openfish_host: target must be an absolute OpenFish.app path" >&2; exit 2 ;;
esac
[[ -d "$APP_BUNDLE/Contents" ]] || { echo "package_openfish_host: app bundle is absent" >&2; exit 1; }

NODE_VERSION="24.17.0"
UV_VERSION="0.12.5"
TARGET_ARCH="${2:-$(uname -m)}"
case "$TARGET_ARCH" in
  arm64) NODE_PLATFORM="darwin-arm64"; UV_PLATFORM="aarch64-apple-darwin" ;;
  x86_64) NODE_PLATFORM="darwin-x64"; UV_PLATFORM="x86_64-apple-darwin" ;;
  *) echo "package_openfish_host: unsupported target architecture $TARGET_ARCH" >&2; exit 1 ;;
esac

CACHE_DIR="$ROOT_DIR/.build/openfish-runtime-cache"
STAGE_DIR="$ROOT_DIR/.build/openfish-host-runtime"
RUNTIME_DIR="$APP_BUNDLE/Contents/Resources/OpenFishHostRuntime"
ARCHIVE="node-v${NODE_VERSION}-${NODE_PLATFORM}.tar.xz"
ARCHIVE_PATH="$CACHE_DIR/$ARCHIVE"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}"
UV_ARCHIVE="uv-${UV_PLATFORM}.tar.gz"
UV_ARCHIVE_PATH="$CACHE_DIR/$UV_ARCHIVE"
UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"

mkdir -p "$CACHE_DIR" "$STAGE_DIR"
expected="$(curl --fail --location "$NODE_URL/SHASUMS256.txt" | awk -v archive="$ARCHIVE" '$2 == archive { print $1; exit }')"
[[ -n "$expected" ]] || { echo "package_openfish_host: Node checksum is absent" >&2; exit 1; }
if [[ -f "$ARCHIVE_PATH" ]]; then
  actual="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{ print $1 }')"
  [[ "$actual" == "$expected" ]] || rm -f "$ARCHIVE_PATH"
fi
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  curl --fail --location --retry 3 --output "$ARCHIVE_PATH.part" "$NODE_URL/$ARCHIVE"
  actual="$(shasum -a 256 "$ARCHIVE_PATH.part" | awk '{ print $1 }')"
  [[ "$actual" == "$expected" ]] || { echo "package_openfish_host: Node checksum mismatch" >&2; exit 1; }
  mv "$ARCHIVE_PATH.part" "$ARCHIVE_PATH"
fi

expected="$(curl --fail --location "$UV_URL/$UV_ARCHIVE.sha256" | awk '{print $1; exit}')"
[[ -n "$expected" ]] || { echo "package_openfish_host: uv checksum is absent" >&2; exit 1; }
if [[ -f "$UV_ARCHIVE_PATH" ]]; then
  actual="$(shasum -a 256 "$UV_ARCHIVE_PATH" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || rm -f "$UV_ARCHIVE_PATH"
fi
if [[ ! -f "$UV_ARCHIVE_PATH" ]]; then
  curl --fail --location --retry 3 --output "$UV_ARCHIVE_PATH.part" "$UV_URL/$UV_ARCHIVE"
  actual="$(shasum -a 256 "$UV_ARCHIVE_PATH.part" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "package_openfish_host: uv checksum mismatch" >&2; exit 1; }
  mv "$UV_ARCHIVE_PATH.part" "$UV_ARCHIVE_PATH"
fi

rm -rf "$STAGE_DIR/app" "$STAGE_DIR/node" "$STAGE_DIR/uv" "$RUNTIME_DIR"
mkdir -p "$STAGE_DIR/app" "$STAGE_DIR/node" "$STAGE_DIR/uv" "$RUNTIME_DIR"
pnpm --config.inject-workspace-packages=true \
  --config.node-linker=hoisted \
  --config.dangerously-allow-all-builds=true \
  --filter @deepseek-ai/dsh deploy "$STAGE_DIR/app"
tar -xJf "$ARCHIVE_PATH" -C "$STAGE_DIR/node" --strip-components=1
tar -xzf "$UV_ARCHIVE_PATH" -C "$STAGE_DIR/uv" --strip-components=1

cp -R "$STAGE_DIR/app" "$RUNTIME_DIR/app"
cp -R "$STAGE_DIR/node" "$RUNTIME_DIR/node"
mkdir -p "$RUNTIME_DIR/uv"
cp "$STAGE_DIR/uv/uv" "$RUNTIME_DIR/uv/uv"
chmod +x "$RUNTIME_DIR/node/bin/node"
chmod +x "$RUNTIME_DIR/uv/uv"
node "$ROOT_DIR/scripts/sanitize-openfish-runtime.mjs" "$RUNTIME_DIR/app"
RUNTIME_ID="$(cd "$RUNTIME_DIR/app" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
printf '{"node":"%s","uv":"%s","architecture":"%s","runtimeId":"%s"}\n' "$NODE_VERSION" "$UV_VERSION" "$NODE_PLATFORM" "$RUNTIME_ID" > "$RUNTIME_DIR/runtime.json"
echo "packaged standalone Open Fish Host runtime at $RUNTIME_DIR"
