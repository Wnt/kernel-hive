#!/bin/bash
# stop-station-qemu.sh <tile> — bounded pidfile-owned QEMU teardown for streamhost@.
# Signal only the recorded tile process: TERM first, then KILL after 10 seconds.
# Once it is gone, remove only that tile's stale pidfile and QMP socket.
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

# x11 tiles (SH_CAPTURE=x11, IRIX/issue #20) have no QEMU/QMP: hand off to the
# Xvfb+emulator teardown helper (keyed on the SH_STATION_RUNTIME marker).
if [ "${SH_STATION_RUNTIME:-}" = "x11" ]; then
  exec "$(dirname "$0")/stop-station-x11.sh" "$TILE"
fi

BASE="/data/vms/streamhost/stations/$TILE"
PIDFILE="$BASE/qemu.pid"
QMP="$BASE/qmp.sock"

# PVE owns the guest process. In particular, a daemon restart must only detach
# and re-attach streamhost; it must never stop or restart the VM.
[ "${SH_QEMU_MODE:-}" = "pve" ] && exit 0

[ -f "$PIDFILE" ] || exit 0

PID="$(cat "$PIDFILE" 2>/dev/null || true)"
case "$PID" in
  '' | *[!0-9]*) ;;
  *)
    if kill -0 "$PID" 2>/dev/null; then
      kill -TERM "$PID" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.5
      done
      if kill -0 "$PID" 2>/dev/null; then
        kill -KILL "$PID" 2>/dev/null || true
      fi
    fi
    ;;
esac

rm -f -- "$PIDFILE" "$QMP"
