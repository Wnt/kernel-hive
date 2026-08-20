#!/usr/bin/env bash
# prove-no-upstream.sh — the security proof of the retronet web proxy: it NEVER
# opens a socket to the real internet.
#
# The property is a property of proxy.py's code, identical wherever it runs, so
# this proves it the cheapest honest way: run that exact code under strace on
# labhost (the gateway CT has no strace), drive it with a corpus HIT, a MISS for
# an uncached host, and a SEARCH request, and read every connect() it made.
#
# PASS means: across all three, the proxy opened ZERO connections to any
# non-loopback address, and the only outbound socket at all was to the CT-local
# search backend (a loopback address). A miss touches no socket; there is no
# upstream and no fallback fetch.
#
# Runnable standalone (no CT, no root). Green-gate + rerun any time.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PYTHON:-python3}"
command -v strace >/dev/null 2>&1 || {
  echo "prove-no-upstream: needs strace" >&2
  exit 2
}
command -v curl >/dev/null 2>&1 || {
  echo "prove-no-upstream: needs curl" >&2
  exit 2
}

TMP="$(mktemp -d)"
TRACE="$TMP/connect.trace"
PGID=""
cleanup() {
  [ -n "$PGID" ] && kill -- "-$PGID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# A throwaway corpus holding only the synthetic sample, so the HIT is real.
mkdir -p "$TMP/corpus"
cp -r "$HERE/sample-corpus/example.museum" "$TMP/corpus/"
cp "$HERE/sample-corpus/sites.json" "$TMP/corpus/"

free_port() { "$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
PORT="$(free_port)"
ORIGIN_PORT="$(free_port)"  # the :80 origin door, on a local port here (can't bind 80/the CT IP on labhost)
BACKEND_PORT="$(free_port)" # left CLOSED — the search connect() still shows in the trace

export RN_PROXY_LISTEN="127.0.0.1:$PORT"
export RN_PROXY_ORIGIN_LISTEN="127.0.0.1:$ORIGIN_PORT"
export RN_PROXY_CORPUS="$TMP/corpus"
export RN_PROXY_SEARCH_HOSTS="search.retronet"
export RN_PROXY_SEARCH_BACKEND="127.0.0.1:$BACKEND_PORT"

# strace as the PARENT of python: every connect() from exec onward is traced,
# with no attach race. setsid puts it in its own process group so cleanup can
# take down strace and the python it wraps together.
setsid strace -f -e trace=connect -o "$TRACE" "$PY" "$HERE/proxy.py" >"$TMP/proxy.log" 2>&1 &
PGID=$!

ready=0
for _ in $(seq 40); do
  if nc -z -w 1 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" = 1 ] || {
  echo "prove-no-upstream: proxy did not start" >&2
  cat "$TMP/proxy.log" >&2
  exit 1
}

# Drive the three request classes through the FORWARD proxy, plus a HIT and a
# MISS through the :80 ORIGIN door (origin-form, Host header) — the no-proxy web
# path — so the proof covers both doors' request handling.
px="127.0.0.1:$PORT"
og="127.0.0.1:$ORIGIN_PORT"
curl -s -o /dev/null -x "$px" "http://example.museum/" || true         # HIT (proxy)
curl -s -o /dev/null -x "$px" "http://nope.invalid/" || true           # MISS (proxy)
curl -s -o /dev/null -x "$px" "http://search.retronet/?q=test" || true # SEARCH -> backend
curl -s -o /dev/null "http://$og/" -H "Host: example.museum" || true   # HIT (:80 origin)
curl -s -o /dev/null "http://$og/" -H "Host: nope.invalid" || true     # MISS (:80 origin)
sleep 0.2                                                              # let strace flush the trace

# --- read the verdict out of the trace --------------------------------------
# Every line with -e trace=connect is a connect() call. INET connects are the
# only ones that could reach a network; classify them by destination address.
inet_all="$(grep -E 'connect\([0-9]+, \{sa_family=AF_INET6?' "$TRACE" 2>/dev/null || true)"
inet_loop="$(printf '%s\n' "$inet_all" | grep -E 'inet_addr\("127\.|inet6_addr\("::1"|inet_pton\(AF_INET6, "::1"' || true)"
n_all="$(printf '%s' "$inet_all" | grep -c 'connect(' || true)"
n_loop="$(printf '%s' "$inet_loop" | grep -c 'connect(' || true)"
n_nonloop=$((n_all - n_loop))

echo "connect() to INET addresses:      $n_all"
echo "  of those, to loopback:          $n_loop"
echo "  of those, to a NON-loopback:    $n_nonloop"
if [ "$n_all" -gt 0 ]; then
  echo "  (the loopback connect is the search route to the backend:)"
  printf '%s\n' "$inet_loop" | sed 's/^/    /'
fi

if [ "$n_nonloop" -ne 0 ]; then
  echo "FAIL: the proxy opened a socket to a non-loopback address:" >&2
  printf '%s\n' "$inet_all" | grep -vE 'inet_addr\("127\.|inet6_addr\("::1"' | sed 's/^/  /' >&2
  exit 1
fi
if [ "$n_loop" -lt 1 ]; then
  echo "FAIL: the search request opened no backend socket — the test proved nothing" >&2
  exit 1
fi
echo "PASS: zero non-loopback connects; the only egress was the loopback search backend."
