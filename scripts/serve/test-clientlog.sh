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
  CLIENTCMD_AUDIT="$TMP/clientcmd-audit.jsonl" \
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

# 1. The OBSERVABILITY plane is open on this listener, by design. Telemetry and
# the command POLL must work for every session, always — a visitor whose stream
# failed is the one worth reaching, and they have no token. Restore is likewise
# untokened (LAN-gated + non-destructive). What is NOT open is issuing a
# command; that is section 6.
c=$(code -X POST "$BASE/clientlog" --data '{"event":"untokened"}')
check "untokened clientlog -> 200" 200 "$c"
c=$(code "$BASE/clientcmd?since=0")
check "untokened clientcmd poll -> 200" 200 "$c"
c=$(code -X POST "$BASE/restore/win95")
check "untokened restore -> 200" 200 "$c"
check "untokened restore executed" present \
  "$(if [ -e "$TMP/reset-proof" ]; then echo present; else echo absent; fi)"
rm -f "$TMP/reset-proof" "$TMP/clientlog.jsonl"

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

# 6. The ENQUEUE is box-side only: a loopback peer AND the token. Without the
# token it is a flat 404 — the path does not admit to existing — and the queue
# file is never created.
c=$(code -X POST "$BASE/clientcmd/admin" --data '{"cmd":"snapshot","tile":"amiga"}')
check "enqueue no token -> 404" 404 "$c"
c=$(code -X POST "$BASE/clientcmd/admin" -H 'X-Admin-Token: wrong' --data '{"cmd":"snapshot","tile":"amiga"}')
check "enqueue bad token -> 404" 404 "$c"
check "queue untouched by denied posts" absent \
  "$(if [ -e "$TMP/clientcmd.json" ]; then echo present; else echo absent; fi)"

# 7. admin with token -> 200; eval needs NO opt-in any more; unknown -> 400
c=$(code -X POST "$BASE/clientcmd/admin" -H "X-Admin-Token: $TOKEN" --data '{"cmd":"snapshot","tile":"amiga"}')
check "admin enqueue snapshot -> 200" 200 "$c"
check "enqueue reply seq=1" '{"ok": true, "seq": 1}' "$(cat "$TMP/body")"
c=$(code -X POST "$BASE/clientcmd/admin" -H "X-Admin-Token: $TOKEN" --data '{"cmd":"verbose","tile":"*"}')
check "admin enqueue verbose -> 200" 200 "$c"
c=$(code -X POST "$BASE/clientcmd/admin" -H "X-Admin-Token: $TOKEN" --data \
  '{"cmd":"eval","tile":"win95","args":{"code":"return await Promise.resolve(42)","sessionId":"deadbeef"}}')
check "admin enqueue eval (no opt-in needed) -> 200" 200 "$c"
check "eval entered queue" 3 "$(python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["seq"])' "$TMP/clientcmd.json")"
check "every issued command is audited" 3 "$(wc -l <"$TMP/clientcmd-audit.jsonl")"
check "audit names cmd + target + issuer, never the token" true \
  "$(python3 -c '
import json, sys
rows = [json.loads(x) for x in open(sys.argv[1])]
r = rows[-1]
print(str(r["cmd"] == "eval" and r["tile"] == "win95" and r["sessionId"] == "deadbeef"
          and r["issuedBy"].startswith("token@") and "return await" in r["code"]
          and not any(sys.argv[2] in json.dumps(x) for x in rows)).lower())' \
    "$TMP/clientcmd-audit.jsonl" "$TOKEN")"
c=$(code -X POST "$BASE/clientcmd/admin" -H "X-Admin-Token: $TOKEN" --data '{"cmd":"rm -rf","tile":"*"}')
check "unknown cmd -> 400" 400 "$c"

# 8. authenticated poll filtering: only cmds with seq > since come back
poll() {
  curl -sk "${AUTH[@]}" "$BASE/clientcmd?since=$1" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d["seq"], len(d["cmds"]))'
}
check "since=0 -> seq 3, 3 cmds" "3 3" "$(poll 0)"
check "since=1 -> seq 3, 2 cmds" "3 2" "$(poll 1)"
check "since=3 -> seq 3, 0 cmds" "3 0" "$(poll 3)"
# The poll needs no token at all: that is what makes every session reachable.
check "poll without a token sees the same queue" "3 3" \
  "$(curl -sk "$BASE/clientcmd?since=0" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d["seq"], len(d["cmds"]))')"

# 9. authenticated restore reaches only the manifest-approved reset helper.
c=$(code -X POST "$BASE/restore/win95" "${AUTH[@]}")
check "authenticated restore -> 200" 200 "$c"
check "restore ran expected tile" win95 "$(cat "$TMP/reset-proof")"
c=$(code -X POST "$BASE/restore/not-a-tile" "${AUTH[@]}")
check "unknown authenticated restore -> 404" 404 "$c"

# 10. Public UI/signaling/WebRTC stay reachable without an admin token. A
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

# 12. OSG_ADMIN_EVAL is now an explicit DISABLE. A second server started with
# =0 must refuse a new eval AND filter an already-queued one out of its poll,
# while the default server (this $BASE) serves it.
WEBROOT="$TMP/webroot" SIGNAL_CONFIG="$TMP/tiles.json" \
  CERT="$TMP/cert.pem" KEY="$TMP/key.pem" \
  BIND_IP=127.0.0.1 PORT=$EVAL_PORT OSG_ADMIN_EVAL=0 \
  CLIENTLOG="$TMP/clientlog.jsonl" CLIENTCMD="$TMP/clientcmd.json" \
  CLIENTCMD_TOKEN="$TMP/pki/clientcmd.token" \
  CLIENTCMD_AUDIT="$TMP/clientcmd-audit.jsonl" \
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
check "eval enqueue on a DISABLED server -> 403" 403 "$c"
check "eval args preserved on the enabled server" true "$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))["cmds"][-1]
print(str(c["cmd"] == "eval" and c["args"] == {
    "code": "return await Promise.resolve(42)", "sessionId": "deadbeef"
}).lower())
' "$TMP/clientcmd.json")"
check "enabled server serves the eval queue entry" "3 1" "$(poll 2)"
got=$(curl -sk "$EVAL_BASE/clientcmd?since=2" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(d["seq"], len(d["cmds"]))')
check "disabled server filters eval out of its poll" "3 0" "$got"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "PASS: all $PASS assertions green"
else
  echo "FAIL: $FAILED of $((PASS + FAILED)) assertions failed"
  exit 1
fi
