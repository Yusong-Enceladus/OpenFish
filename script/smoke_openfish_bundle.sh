#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENFISH_REPO_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/script/openfish_build_paths.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 /absolute/path/OpenFish.app [arm64|x86_64]" >&2
  exit 2
fi

APP_BUNDLE="$1"
RUNTIME="$APP_BUNDLE/Contents/Resources/OpenFishHostRuntime"
NODE="$RUNTIME/node/bin/node"
BUN="$RUNTIME/app/node_modules/bun/bin/bun.exe"
UV="$RUNTIME/uv/uv"
HOST="$RUNTIME/app/lib/bin.js"
HOST_NPM="$RUNTIME/app/node_modules/npm/bin/npm-cli.js"
DRIVER_NPM="$RUNTIME/node/lib/node_modules/npm/bin/npm-cli.js"
[[ -x "$NODE" && -x "$BUN" && -x "$UV" && -f "$HOST" && -f "$HOST_NPM" && -f "$DRIVER_NPM" ]] || {
  echo "smoke_openfish_bundle: embedded Node/Bun/uv/Host runtime is incomplete" >&2
  exit 1
}
"$BUN" --version >/dev/null
"$UV" --version >/dev/null
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

SMOKE_ROOT="$(mktemp -d "$OPENFISH_TEMP_ROOT/openfish-bundle-smoke.XXXXXX")"
PORT=31973
REMOTE_TLS_PORT=31974
HOST_PID=""
cleanup() {
  if [[ -n "$HOST_PID" ]]; then kill "$HOST_PID" 2>/dev/null || true; fi
  rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

TLS_CERT="$SMOKE_ROOT/host-cert.pem"
TLS_KEY="$SMOKE_ROOT/host-key.pem"
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 1 \
  -subj '/CN=OpenFish Release Smoke' -keyout "$TLS_KEY" -out "$TLS_CERT" >/dev/null 2>&1
chmod 600 "$TLS_KEY"
chmod 644 "$TLS_CERT"

# Exercise the packaged security topology, not only local HTTP: plaintext is
# explicitly loopback-only and the second listener is TLS-only on all network
# interfaces. These environment variables are the same contract supplied by
# the native Mac launcher after it creates its durable app-owned identity.
DSH_HOME="$SMOKE_ROOT/state" OPENFISH_EMBEDDED_RUNTIME_ROOT="$RUNTIME" \
  OPENFISH_TLS_CERT_PATH="$TLS_CERT" OPENFISH_TLS_PRIVATE_KEY_PATH="$TLS_KEY" \
  OPENFISH_TLS_PORT="$REMOTE_TLS_PORT" \
  "$NODE" "$HOST" --profile x --host 127.0.0.1 --port "$PORT" --no-open \
  >"$SMOKE_ROOT/host.log" 2>&1 &
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
if (health.plainHost !== "127.0.0.1" || health.secureRemotePort !== Number(process.argv[2])) process.exit(1)
' "$SMOKE_ROOT/health.json" "$REMOTE_TLS_PORT"

if ! curl --fail --silent --insecure \
  "https://127.0.0.1:$REMOTE_TLS_PORT/x-native/v2/health" >/dev/null; then
  echo "smoke_openfish_bundle: packaged TLS listener is unavailable" >&2
  exit 1
fi

# A loopback TLS check does not exercise the DNS-rebinding authority fence:
# loopback short-circuits before the deployment-derived trusted-host list. Use
# a real active LAN literal so a stale packaged runtime cannot look healthy on
# the Mac while every iPhone request fails at the same route.
LAN_IP="$($NODE -e '
const { networkInterfaces } = require("node:os")
const address = Object.values(networkInterfaces()).flat()
  .find(value => value && value.family === "IPv4" && !value.internal)?.address
if (address) process.stdout.write(address)
')"
if [[ -z "$LAN_IP" ]] || ! curl --fail --silent --insecure \
  "https://$LAN_IP:$REMOTE_TLS_PORT/x-native/v2/health" >"$SMOKE_ROOT/lan-health.json"; then
  echo "smoke_openfish_bundle: packaged TLS listener rejected its active LAN authority" >&2
  exit 1
fi
$NODE -e '
const fs = require("node:fs")
const health = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
if (!health.ok || health.product !== "opencodex" || health.protocolVersion !== "v2") process.exit(1)
' "$SMOKE_ROOT/lan-health.json"

# Request schemas protect the registry, not only TypeScript callers. Exercise
# the packaged, registered route and prove malformed input cannot commit a
# device before an open-source user ever reaches the UI.
curl --fail --silent "http://127.0.0.1:$PORT/x-native/v2/devices" >"$SMOKE_ROOT/devices-before.json"
INVALID_PAIR_STATUS="$(curl --silent --output "$SMOKE_ROOT/invalid-pair.json" \
  --write-out '%{http_code}' --request POST --header 'content-type: application/json' \
  --data '{}' "http://127.0.0.1:$PORT/x-native/v2/pair")"
if [[ "$INVALID_PAIR_STATUS" != "400" ]]; then
  echo "smoke_openfish_bundle: malformed pairing input was not rejected" >&2
  exit 1
fi
curl --fail --silent "http://127.0.0.1:$PORT/x-native/v2/devices" >"$SMOKE_ROOT/devices-after.json"
$NODE -e '
const fs = require("node:fs")
const before = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
const failure = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
const after = JSON.parse(fs.readFileSync(process.argv[3], "utf8"))
if (!Array.isArray(before) || !Array.isArray(after) || before.length !== after.length) process.exit(1)
if (failure?.error?.code !== "invalid-request") process.exit(1)
' "$SMOKE_ROOT/devices-before.json" "$SMOKE_ROOT/invalid-pair.json" "$SMOKE_ROOT/devices-after.json"

LISTENERS="$(lsof -nP -a -p "$HOST_PID" -iTCP -sTCP:LISTEN)"
if ! rg -q "127\\.0\\.0\\.1:$PORT \\(LISTEN\\)" <<<"$LISTENERS" \
  || rg -q "\\*:$PORT \\(LISTEN\\)" <<<"$LISTENERS" \
  || ! rg -q "\\*:$REMOTE_TLS_PORT \\(LISTEN\\)" <<<"$LISTENERS"; then
  echo "smoke_openfish_bundle: plaintext/TLS listener isolation is incorrect" >&2
  exit 1
fi

if [[ -d "$SMOKE_ROOT/state" ]] && rg -n '"defaultHarnessId"\s*:\s*"dsh"' "$SMOKE_ROOT/state" >/dev/null 2>&1; then
  echo "smoke_openfish_bundle: fresh state silently selected DSH" >&2
  exit 1
fi

echo "OpenFish clean-state embedded Host smoke passed"
