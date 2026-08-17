#!/bin/bash
# De-bridging conversion campaign: run ONE streamhost daemon for one
# conversion rig, in the background, from a plain env file. The spike's
# run-streamhost.sh generalized to /data/vms/sandbox/debridge-<station>/.
#
# NOT a `streamhost@<station>` unit on purpose — the systemd template's
# session-key drop-in would demand gallery tickets for a rig the gateway has
# never heard of (see scripts/debridge-spike/run-streamhost.sh, same shape).
#
# WHICH BINARY: $RIG/streamhost.bin must be a symlink into
# /usr/local/lib/streamhost/streamhost-<sha>. There is deliberately NO
# fallback to a station's `current`: a rig that has not pinned its daemon is
# a rig whose acceptance run proves nothing ("it exists" is not "it is mine").
#
#   usage: rig-streamhost.sh <station> [start|stop|status]
set -euo pipefail
STATION="${1:?usage: rig-streamhost.sh <station> [start|stop|status]}"
ACT="${2:-start}"
D="/data/vms/sandbox/debridge-$STATION"
[ -d "$D" ] || {
  echo "no such rig: $D" >&2
  exit 2
}
BIN="$(readlink -f "$D/streamhost.bin" 2>/dev/null || true)"
[ -x "$BIN" ] || {
  echo "rig has no pinned daemon: point $D/streamhost.bin into /usr/local/lib/streamhost/" >&2
  exit 2
}
PIDF="$D/streamhost.pid"

running() {
  [ -f "$PIDF" ] || return 1
  [ "$(readlink -f "/proc/$(cat "$PIDF")/exe" 2>/dev/null)" = "$BIN" ]
}

case "$ACT" in
  stop)
    # Resolve the real process before signalling it: a recycled pid must not
    # be killed because a stale file names it.
    if running; then
      P="$(cat "$PIDF")"
      kill "$P" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$P" 2>/dev/null || break
        sleep 0.25
      done
    fi
    rm -f "$PIDF"
    echo "$STATION rig streamhost stopped"
    ;;
  status)
    if running; then
      echo "$STATION rig streamhost RUNNING pid=$(cat "$PIDF") bin=$BIN"
    else
      echo "$STATION rig streamhost not running"
    fi
    ;;
  start)
    if running; then
      echo "$STATION rig streamhost already running pid=$(cat "$PIDF")"
      exit 0
    fi
    set -a
    # shellcheck disable=SC1091
    . "$D/stream.env"
    set +a
    nohup "$BIN" >"$D/streamhost.log" 2>&1 &
    echo $! >"$PIDF"
    for _ in $(seq 1 40); do
      [ -f "$D/signaling.json" ] && break
      sleep 0.25
    done
    echo "$STATION rig streamhost pid=$(cat "$PIDF") bin=$BIN"
    cat "$D/signaling.json" 2>/dev/null || true
    ;;
  *)
    echo "unknown action: $ACT" >&2
    exit 2
    ;;
esac
