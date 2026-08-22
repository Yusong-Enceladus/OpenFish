#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_PORT="${OPENCODEX_HOST_PORT:-3080}"

cd "$ROOT_DIR"

echo "OpenCodex Host: http://127.0.0.1:${HOST_PORT} (LAN/Tailscale clients use this Mac's reachable IP)"
echo "Remote DSH API access requires an OpenCodex device bearer; pairing codes can only be created locally."

HOST_ARGS=(--profile x --port "$HOST_PORT" --no-open)
if [[ -n "${OPENCODEX_HOST_ADDRESS:-}" ]]; then
  HOST_ARGS+=(--host "$OPENCODEX_HOST_ADDRESS")
fi

# LAN IP literals are discovered from the all-interfaces bind, but iPhone uses
# this Mac's stable Bonjour name so it keeps working across DHCP changes. Trust
# that exact DNS-rebinding authority as well; deployments may override it.
TRUSTED_HOST="${OPENCODEX_TRUSTED_HOST:-}"
if [[ -z "$TRUSTED_HOST" ]]; then
  LOCAL_HOSTNAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
  TRUSTED_HOST="${LOCAL_HOSTNAME}.local"
fi
HOST_ARGS+=(--trusted-host "$TRUSTED_HOST")

NODE_BIN="${OPENCODEX_NODE_BIN:-$(command -v node)}"
exec "$NODE_BIN" --import tsx/esm "$ROOT_DIR/apps/cli/src/bin.ts" "${HOST_ARGS[@]}" "$@"
