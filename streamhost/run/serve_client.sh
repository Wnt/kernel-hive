#!/bin/bash
# Serve the standalone WebCodecs test client on localhost (a secure context, so
# WebTransport is allowed). Pulls the current cert hash from the compute host,
# substitutes it + the server URL into web/client.html, and serves it.
#
# Usage: run/serve_client.sh [host] [port] [serve_port]
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$HERE/../scripts/lib/local-env.sh"
HOST="${1:-${SH_HOST_IP:-192.0.2.10}}"
PORT="${2:-4433}"
SERVE_PORT="${3:-8971}"
KEY="${LAB_KEY:-$HOME/.ssh/lab_key}"

HASH="$(ssh -i "$KEY" root@"$HOST" 'cat /data/vms/streamhost/run951/cert_hash_b64.txt')"
OUT="$(mktemp -d)/streamhost-client"
mkdir -p "$OUT"
sed -e "s|__CERT_HASH__|$HASH|" \
  -e "s|__SERVER_URL__|https://$HOST:$PORT/stream|" \
  "$HERE/web/client.html" >"$OUT/index.html"
echo "cert hash: $HASH"
echo "serving $OUT on http://localhost:$SERVE_PORT/  (open in Chrome)"
cd "$OUT" && exec python3 -m http.server "$SERVE_PORT" --bind 127.0.0.1
