#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST_JS="$SCRIPT_DIR/pokemon-showdown-host.js"

if [[ ! -f "$HOST_JS" ]]; then
  echo "Missing host script: $HOST_JS"
  exit 1
fi

HOST_BIND="${SHOWDOWN_HOST_BIND:-127.0.0.1}"
HOST_PORT="${SHOWDOWN_HOST_PORT:-8787}"
HOST_LOG="$(mktemp -t showdown-host.XXXXXX.log)"
TUN_LOG="$(mktemp -t showdown-tunnel.XXXXXX.log)"
HOST_PID=""
TUN_PID=""

cleanup() {
  set +e
  pkill -P $$ >/dev/null 2>&1 || true
  if [[ -n "$TUN_PID" ]]; then kill "$TUN_PID" 2>/dev/null || true; fi
  if [[ -n "$HOST_PID" ]]; then kill "$HOST_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

if ! command -v cloudflared >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing cloudflared (one-time, via Homebrew)..."
    brew install cloudflared
  else
    echo "cloudflared is required for cross-WiFi access. Install it first."
    exit 1
  fi
fi

echo "Starting Pokemon Showdown host on $HOST_BIND:$HOST_PORT..."
SHOWDOWN_HOST_BIND="$HOST_BIND" SHOWDOWN_HOST_PORT="$HOST_PORT" node "$HOST_JS" >"$HOST_LOG" 2>&1 &
HOST_PID="$!"

sleep 1
if ! kill -0 "$HOST_PID" 2>/dev/null; then
  echo "Host failed to start."
  cat "$HOST_LOG"
  exit 1
fi

echo "Starting public tunnel..."
cloudflared tunnel --url "http://$HOST_BIND:$HOST_PORT" --no-autoupdate >"$TUN_LOG" 2>&1 &
TUN_PID="$!"

PUBLIC_BASE=""
for _ in {1..80}; do
  PUBLIC_BASE="$(rg -o "https://[-a-z0-9]+\\.trycloudflare\\.com" "$TUN_LOG" | head -n1 || true)"
  if [[ -n "$PUBLIC_BASE" ]]; then
    break
  fi
  sleep 0.5
done

if [[ -z "$PUBLIC_BASE" ]]; then
  echo "Failed to get public tunnel URL."
  echo "---- host log ----"
  cat "$HOST_LOG"
  echo "---- tunnel log ----"
  cat "$TUN_LOG"
  exit 1
fi

echo ""
echo "Cross-WiFi URL (open this on any device):"
echo "  ${PUBLIC_BASE}/pokemon-showdown"
echo ""
echo "If running from another HTML page/tester, use proxy param:"
echo "  ?proxy=${PUBLIC_BASE}&wsPath=/showdown"
echo ""
echo "Keep this terminal open. Press Ctrl+C to stop."
echo ""

# Stream tunnel logs while running.
tail -f "$TUN_LOG"
