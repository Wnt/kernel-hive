#!/usr/bin/env bash
# test-clientlog.sh — UI-independent smoke test for the /clientlog and
# /clientcmd endpoints of osgallery-https-server.py.
#
# Runs entirely locally: throwaway self-signed TLS cert, throwaway port,
# temp WEBROOT / queue / log / token. Needs python3, curl, openssl.
# Exit 0 == every assertion green.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SERVER=$HERE/osgallery-https-server.py
TMP=$(mktemp -d)
PORT=$((20000 + RANDOM % 20000))
EVAL_PORT=$((PORT + 1))
PID=
EVAL_PID=

cleanup() {
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi
  if [ -n "$EVAL_PID" ]; then kill "$EVAL_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# Throwaway TLS material + minimal webroot + two ordinary stations + admin token.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" \
  -out "$TMP/cert.pem" -days 1 -subj /CN=localhost >/dev/null 2>&1
mkdir -p "$TMP/webroot" "$TMP/pki"
echo '<!doctype html><title>spa</title>ok' >"$TMP/webroot/index.html"
printf 'test-cert-hash\n' >"$TMP/cert_hash_b64.txt"
printf '{"win95":{"udpPort":54091,"hashFile":"%s"},"freedos":{"udpPort":54095,"hashFile":"%s"}}\n' \
  "$TMP/cert_hash_b64.txt" "$TMP/cert_hash_b64.txt" >"$TMP/tiles.json"
TOKEN=$(openssl rand -hex 32)
printf '%s\n' "$TOKEN" >"$TMP/pki/clientcmd.token"
cat >"$TMP/reset-tile.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$RESET_PROOF"
printf 'restored %s\n' "$1"
EOF
printf '{"tiles":{"win95":{"mode":"loadvm"}}}\n' >"$TMP/golden-manifest.json"

WEBROOT="$TMP/webroot" SIGNAL_CONFIG="$TMP/tiles.json" \
  CERT="$TMP/cert.pem" KEY="$TMP/key.pem" \
  BIND_IP=127.0.0.1 PORT=$PORT \
  CLIENTLOG="$TMP/clientlog.jsonl" CLIENTCMD="$TMP/clientcmd.json" \
  CLIENTCMD_TOKEN="$TMP/pki/clientcmd.token" \
  RESET_SCRIPT="$TMP/reset-tile.sh" GOLDEN_MANIFEST="$TMP/golden-manifest.json" \
  RESET_PROOF="$TMP/reset-proof" \
  WEBRTC_BRIDGE_UPSTREAM=http://127.0.0.1:1 \
  python3 "$SERVER" 2>"$TMP/server.log" &
PID=$!

BASE="https://127.0.0.1:$PORT"
for _ in $(seq 1 50); do
  if curl -skf "$BASE/healthz" >/dev/null 2>&1; then break; fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: server died on startup:"
    cat "$TMP/server.log"
    exit 1
  fi
  sleep 0.1
done

PASS=0 FAILED=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "ok   $1"
  else
    FAILED=$((FAILED + 1))
    echo "FAIL $1: expected [$2] got [$3]"
  fi
}
code() { curl -sk -o "$TMP/body" -w '%{http_code}' "$@" || true; }
AUTH=(-H "X-Admin-Token: $TOKEN")

# 1. Even a loopback/RFC1918-looking peer has no authority without the token.
c=$(code -X POST "$BASE/clientlog" --data '{"event":"denied"}')
check "loopback clientlog without token -> 403" 403 "$c"
c=$(code "$BASE/clientcmd?since=0")
check "loopback clientcmd poll without token -> 403" 403 "$c"
c=$(code -X POST "$BASE/restore/win95")
check "loopback restore without token -> 403" 403 "$c"
check "denied restore did not execute" absent \
  "$(if [ -e "$TMP/reset-proof" ]; then echo present; else echo absent; fi)"

# 2. valid authenticated event -> 200 {"ok":true}, one JSONL line
c=$(code -X POST "$BASE/clientlog" "${AUTH[@]}" -H 'Content-Type: application/json' --data \
  '{"ts":1752300000000,"sessionId":"deadbeef","tile":"amiga","ua":"smoke-ua","event":"connect","detail":"transport ok"}')
check "single event -> 200" 200 "$c"
check "single event body" '{"ok":true}' "$(cat "$TMP/body")"

# 3. valid authenticated ARRAY of events -> 200, two more lines
c=$(code -X POST "$BASE/clientlog" "${AUTH[@]}" --data \
  '[{"event":"stall","tile":"amiga","detail":"watchdog latched"},{"event":"wt-close","tile":"amiga"}]')
check "event array -> 200" 200 "$c"
check "3 JSONL lines total" 3 "$(wc -l <"$TMP/clientlog.jsonl")"
check "srvTs/ip added, client ts -> clientTs" true "$(head -1 "$TMP/clientlog.jsonl" | python3 -c '
import json, sys
r = json.load(sys.stdin)
print(str("srvTs" in r and r["ip"] == "127.0.0.1"
          and r["clientTs"] == 1752300000000 and r["event"] == "connect").lower())')"

# 4. oversized body (~26 KiB > 16 KiB cap) -> 413
python3 -c 'print("[" + ",".join(["{\"event\":\"x\",\"detail\":\"" + "y"*400 + "\"}"] * 64) + "]")' >"$TMP/big.json"
c=$(code -X POST "$BASE/clientlog" "${AUTH[@]}" --data @"$TMP/big.json")
check "oversized body -> 413" 413 "$c"

# 5. bad json -> 400; chunked transfer coding -> 411
c=$(code -X POST "$BASE/clientlog" "${AUTH[@]}" --data 'not json {')
check "bad json -> 400" 400 "$c"
c=$(code -X POST "$BASE/clientlog" "${AUTH[@]}" -H 'Transfer-Encoding: chunked' --data '{"event":"x"}')
check "chunked -> 411" 411 "$c"

# 6. admin without / with wrong token -> 403, queue file never created
c=$(code -X POST "$BASE/clientcmd/admin" --data '{"cmd":"snapshot","tile":"amiga"}')
check "admin no token -> 403" 403 "$c"
c=$(code -X POST "$BASE/clientcmd/admin" -H 'X-Admin-Token: wrong' --data '{"cmd":"snapshot","tile":"amiga"}')
check "admin bad token -> 403" 403 "$c"
check "queue untouched by denied posts" absent \
  "$(if [ -e "$TMP/clientcmd.json" ]; then echo present; else echo absent; fi)"

# 7. admin with token -> 200; eval is default-off; unknown -> 400
c=$(code -X POST "$BASE/clientcmd/admin" -H "X-Admin-Token: $TOKEN" --data '{"cmd":"snapshot","tile":"amiga"}')
check "admin enqueue snapshot -> 200" 200 "$c"
check "enqueue reply seq=1" '{"ok": true, "seq": 1}' "$(cat "$TMP/body")"
c=$(code -X POST "$BASE/clientcmd/admin" -H "X-Admin-Token: $TOKEN" --data '{"cmd":"verbose","tile":"*"}')
check "admin enqueue verbose -> 200" 200 "$c"
c=$(code -X POST "$BASE/clientcmd/admin" -H "X-Admin-Token: $TOKEN" --data \
  '{"cmd":"eval","tile":"win95","args":{"code":"return await Promise.resolve(42)","sessionId":"deadbeef"}}')
check "admin enqueue eval default-off -> 403" 403 "$c"
check "disabled eval did not enter queue" 2 "$(python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["seq"])' "$TMP/clientcmd.json")"
c=$(code -X POST "$BASE/clientcmd/admin" -H "X-Admin-Token: $TOKEN" --data '{"cmd":"rm -rf","tile":"*"}')
check "unknown cmd -> 400" 400 "$c"

# 8. authenticated poll filtering: only cmds with seq > since come back
poll() {
  curl -sk "${AUTH[@]}" "$BASE/clientcmd?since=$1" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d["seq"], len(d["cmds"]))'
}
check "since=0 -> seq 2, 2 cmds" "2 2" "$(poll 0)"
check "since=1 -> seq 2, 1 cmd" "2 1" "$(poll 1)"
check "since=2 -> seq 2, 0 cmds" "2 0" "$(poll 2)"

# 9. authenticated restore reaches only the manifest-approved reset helper.
c=$(code -X POST "$BASE/restore/win95" "${AUTH[@]}")
check "authenticated restore -> 200" 200 "$c"
check "restore ran expected tile" win95 "$(cat "$TMP/reset-proof")"
c=$(code -X POST "$BASE/restore/not-a-tile" "${AUTH[@]}")
check "unknown authenticated restore -> 404" 404 "$c"

# 10. Public SPA/signaling/WebRTC stay reachable without an admin token. A
# missing generic bridge is 502, never a per-station 404 gate.
c=$(code "$BASE/")
check "public SPA index -> 200" 200 "$c"
for tile in win95 freedos; do
  got=$(curl -sk "$BASE/signal/$tile.json" | python3 -c '
import json,sys
d=json.load(sys.stdin); w=d.get("webrtc", {})
print(w.get("offerUrl", ""), len(w.get("iceServers", [])), w.get("jitterBufferTargetMs", ""))')
  check "$tile signal has platform WebRTC" "/webrtc/$tile/offer 0 15" "$got"
  c=$(code -X POST "$BASE/webrtc/$tile/offer" -H 'Content-Type: application/json' \
    --data '{"type":"offer","sdp":"v=0\\r\\n"}')
  check "$tile offer has no per-tile gate" 502 "$c"
done
c=$(code -X POST "$BASE/webrtc/not-a-tile/offer" -H 'Content-Type: application/json' \
  --data '{"type":"offer","sdp":"v=0\\r\\n"}')
check "unknown tile offer -> 404" 404 "$c"

# 11. reserved prefixes: stray GETs must NOT fall through to the UI index
c=$(code "$BASE/clientlog")
check "GET /clientlog -> 404 (not SPA fallback)" 404 "$c"

# 12. A separate explicit opt-in server accepts eval with the same strong token.
WEBROOT="$TMP/webroot" SIGNAL_CONFIG="$TMP/tiles.json" \
  CERT="$TMP/cert.pem" KEY="$TMP/key.pem" \
  BIND_IP=127.0.0.1 PORT=$EVAL_PORT OSG_ADMIN_EVAL=1 \
  CLIENTLOG="$TMP/clientlog.jsonl" CLIENTCMD="$TMP/clientcmd.json" \
  CLIENTCMD_TOKEN="$TMP/pki/clientcmd.token" \
  RESET_SCRIPT="$TMP/reset-tile.sh" GOLDEN_MANIFEST="$TMP/golden-manifest.json" \
  RESET_PROOF="$TMP/reset-proof" \
  WEBRTC_BRIDGE_UPSTREAM=http://127.0.0.1:1 \
  python3 "$SERVER" 2>"$TMP/eval-server.log" &
EVAL_PID=$!
EVAL_BASE="https://127.0.0.1:$EVAL_PORT"
for _ in $(seq 1 50); do
  if curl -skf "$EVAL_BASE/healthz" >/dev/null 2>&1; then break; fi
  if ! kill -0 "$EVAL_PID" 2>/dev/null; then
    echo "FAIL: eval server died on startup:"
    cat "$TMP/eval-server.log"
    exit 1
  fi
  sleep 0.1
done
c=$(code -X POST "$EVAL_BASE/clientcmd/admin" "${AUTH[@]}" --data \
  '{"cmd":"eval","tile":"win95","args":{"code":"return 42","sessionId":"deadbeef"}}')
check "explicit opt-in eval enqueue -> 200" 200 "$c"
check "eval args preserved" true "$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))["cmds"][-1]
print(str(c["cmd"] == "eval" and c["args"] == {
    "code": "return 42", "sessionId": "deadbeef"
}).lower())
' "$TMP/clientcmd.json")"
check "default-off server filters opt-in queue entry" "3 0" "$(poll 2)"
got=$(curl -sk "${AUTH[@]}" "$EVAL_BASE/clientcmd?since=2" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(d["seq"], len(d["cmds"]))')
check "opt-in server serves eval queue entry" "3 1" "$got"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "PASS: all $PASS assertions green"
else
  echo "FAIL: $FAILED of $((PASS + FAILED)) assertions failed"
  exit 1
fi
