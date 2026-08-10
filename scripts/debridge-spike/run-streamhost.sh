#!/bin/bash
# De-bridging spike: run ONE streamhost daemon for one spike arm, in the
# background, from a plain env file.
#
# NOT a `streamhost@<tile>` unit on purpose. The systemd template pulls in
# /etc/systemd/system/streamhost@.service.d/session-key.conf, which sets
# SH_SESSION_KEY and makes every WebTransport session require a ticket minted
# by the public-gallery gateway for a tile the gateway knows about. These arms
# are not exhibits and the gateway has never heard of them, so a probe could
# not connect at all. Running the same binary by hand, without that drop-in, is
# what lets the standalone probe dial the arm directly -- and it also keeps the
# spike out of the production tiles tree entirely.
#
#   usage: run-streamhost.sh <armA|armB> [start|stop|status]
set -euo pipefail
RIG=/data/vms/soltest/debridge-7f3a
ARM="${1:?usage: run-streamhost.sh <armA|armB> [start|stop|status]}"
ACT="${2:-start}"
D="$RIG/$ARM"
[ -d "$D" ] || {
  echo "no such arm: $ARM" >&2
  exit 2
}
BIN="$(readlink -f /usr/local/lib/streamhost/tiles/helenos/current)"
PIDF="$D/streamhost.pid"

running() {
  [ -f "$PIDF" ] || return 1
  [ "$(readlink -f "/proc/$(cat "$PIDF")/exe" 2>/dev/null)" = "$BIN" ]
}

case "$ACT" in
  stop)
    # Resolve the real process before signalling it: a recycled pid must not be
    # killed because a stale file names it.
    if running; then
      P="$(cat "$PIDF")"
      kill "$P" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$P" 2>/dev/null || break
        sleep 0.25
      done
    fi
    rm -f "$PIDF"
    echo "$ARM streamhost stopped"
    ;;
  status)
    if running; then
      echo "$ARM streamhost RUNNING pid=$(cat "$PIDF") bin=$BIN"
    else
      echo "$ARM streamhost not running"
    fi
    ;;
  start)
    if running; then
      echo "$ARM streamhost already running pid=$(cat "$PIDF")"
      exit 0
    fi
    set -a
    # shellcheck disable=SC1090,SC1091
    . "$D/stream.env"
    set +a
    nohup "$BIN" >"$D/streamhost.log" 2>&1 &
    echo $! >"$PIDF"
    for _ in $(seq 1 40); do
      [ -f "$D/signaling.json" ] && break
      sleep 0.25
    done
    echo "$ARM streamhost pid=$(cat "$PIDF") bin=$BIN"
    cat "$D/signaling.json" 2>/dev/null || true
    ;;
  *)
    echo "unknown action: $ACT" >&2
    exit 2
    ;;
esac
