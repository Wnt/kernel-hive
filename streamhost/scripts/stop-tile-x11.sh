#!/bin/bash
# stop-tile-x11.sh <tile> — bounded pidfile-owned teardown for x11-runtime tiles
# (the IRIX/MAME tile, issue #20). Signals only the recorded MAME + Xvfb PIDs
# (under SH_CAPTURE=shm there is no Xvfb and that pidfile simply does not exist):
# TERM first, then KILL after ~10 seconds. Never pkill by name (the pattern would
# also match the ssh/bash wrapper). Mirrors stop-tile-qemu.sh.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 <tile>" >&2
  exit 2
}
TILE="$1"
case "$TILE" in
  *[!a-zA-Z0-9_-]* | '')
    echo "invalid tile name: $TILE" >&2
    exit 2
    ;;
esac

BASE="/data/vms/streamhost/tiles/$TILE"

stop_pidfile() { # $1 = pidfile
  local pidfile="$1" pid
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  case "$pid" in
    '' | *[!0-9]*) ;;
    *)
      if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
          kill -KILL "$pid" 2>/dev/null || true
        fi
      fi
      ;;
  esac
  rm -f -- "$pidfile"
}

# The boot watchdog FIRST — it relaunches MAME on a black-screen hang, so it has
# to be gone before we kill MAME or it would race the teardown. (It also
# self-checks the launch generation and `systemctl is-active`, but killing it
# first makes the ordering unconditional.)
stop_pidfile "$BASE/bootwatch.pid"
# The liveness watchdog relaunches MAME too (on a dead/unresponsive guest), so
# it has to go before MAME for exactly the same reason.
stop_pidfile "$BASE/livewatch.pid"
# MAME next (it drives the display), then its Xvfb.
stop_pidfile "$BASE/mame.pid"
stop_pidfile "$BASE/xvfb.pid"
