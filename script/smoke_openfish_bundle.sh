#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 /absolute/path/OpenFish.app [arm64|x86_64]" >&2
  exit 2
fi

APP_BUNDLE="$1"
RUNTIME="$APP_BUNDLE/Contents/Resources/OpenFishHostRuntime"
NODE="$RUNTIME/node/bin/node"
HOST="$RUNTIME/app/lib/bin.js"
[[ -x "$NODE" && -f "$HOST" ]] || { echo "smoke_openfish_bundle: embedded Host is incomplete" >&2; exit 1; }
if [[ $# -eq 2 ]]; then
  EXPECTED_ARCH="$2"
  case "$EXPECTED_ARCH" in
    arm64) FILE_ARCH='arm64' ;;
    x86_64) FILE_ARCH='x86_64' ;;
    *) echo "smoke_openfish_bundle: unsupported expected architecture $EXPECTED_ARCH" >&2; exit 2 ;;
  esac
  if ! file -b "$NODE" | rg -q "Mach-O 64-bit executable $FILE_ARCH"; then
    echo "smoke_openfish_bundle: embedded Node does not match $EXPECTED_ARCH" >&2
    file "$NODE" >&2
    exit 1
  fi
fi

SMOKE_ROOT="$(mktemp -d)"
PORT=31973
HOST_PID=""
cleanup() {
  if [[ -n "$HOST_PID" ]]; then kill "$HOST_PID" 2>/dev/null || true; fi
  rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

DSH_HOME="$SMOKE_ROOT/state" OPENFISH_EMBEDDED_RUNTIME_ROOT="$RUNTIME" \
  "$NODE" "$HOST" --profile x --port "$PORT" --no-open >"$SMOKE_ROOT/host.log" 2>&1 &
HOST_PID=$!

for _ in {1..120}; do
  if curl --fail --silent "http://127.0.0.1:$PORT/x-native/v2/health" >"$SMOKE_ROOT/health.json"; then
    break
  fi
  if ! kill -0 "$HOST_PID" 2>/dev/null; then
    sed -n '1,120p' "$SMOKE_ROOT/host.log" >&2
    exit 1
  fi
  sleep 0.25
done

node -e '
const fs = require("node:fs")
const health = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
if (!health.ok || health.product !== "opencodex" || health.protocolVersion !== "v2") process.exit(1)
' "$SMOKE_ROOT/health.json"

if [[ -d "$SMOKE_ROOT/state" ]] && rg -n '"defaultHarnessId"\s*:\s*"dsh"' "$SMOKE_ROOT/state" >/dev/null 2>&1; then
  echo "smoke_openfish_bundle: fresh state silently selected DSH" >&2
  exit 1
fi

echo "OpenFish clean-state embedded Host smoke passed"
