#!/bin/bash
# ensure-tile-x11.sh <tile> — idempotent ExecStartPre for x11-runtime streamhost
# tiles (the IRIX/MAME tile, issue #20). Parallels ensure-tile-qemu.sh but for
# the non-QEMU emulator runtime: no QMP, no loadvm. A daemon-only restart must
# not restart the emulator, so if the pidfile-owned emulator is live and its
# frame source is present this is a no-op; otherwise the tracked x11-runtime.sh
# owns a fresh kill-by-pidfile + relaunch (fresh disk copy = pristine).
#
# The liveness proof depends on the CAPTURE MODE, and getting it wrong is not
# cosmetic: under SH_CAPTURE=shm there is no X server at all, so testing for the
# Xvfb socket would fail every time and cold-boot the exhibit (~4.5 min) on every
# daemon restart. shm proves liveness with the published framebuffer instead.
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
MAME_PID="$BASE/mame.pid"
LAUNCHER="$BASE/x11-runtime.sh"
DISPLAY_NUM="${SH_X11_DISPLAY:-:40}"
XSOCK="/tmp/.X11-unix/X${DISPLAY_NUM#:}"
CAPTURE="${SH_CAPTURE:-x11}"
SHM="${SH_SHM_PATH:-$BASE/fb.shm}"

frame_source_live() {
  if [ "$CAPTURE" = shm ]; then
    [ -s "$SHM" ]
  else
    [ -S "$XSOCK" ]
  fi
}

if [ -f "$MAME_PID" ]; then
  PID="$(cat "$MAME_PID" 2>/dev/null || true)"
  case "$PID" in
    '' | *[!0-9]*) ;;
    *)
      if kill -0 "$PID" 2>/dev/null && frame_source_live; then
        exit 0
      fi
      ;;
  esac
fi

[ -x "$LAUNCHER" ] || {
  echo "missing launcher: $LAUNCHER" >&2
  exit 1
}
# Run the emulator inside a transient 3 GiB qcap scope (as the bridge kiosks do):
# streamhost's display backlog is bounded at the source, the MemoryMax cap is the
# outer net. The launcher backgrounds Xvfb+MAME and returns once both are up.
#
# BindsTo= is what makes `systemctl stop` mean it. A bare `systemd-run --scope`
# puts the launcher — and therefore MAME, Xvfb, the boot watchdog and the
# liveness watchdog — in a cgroup that has NO relationship to this service, so
# no KillMode= on the unit can reach them and teardown rested entirely on
# ExecStop finding every pidfile. It did not: an orphaned
# `x11-runtime.sh --livewatch` was observed alive after
# `systemctl stop streamhost@irix`, still able to relaunch the guest, which made
# "the tile is stopped" untrue for every measurement taken with tiles down.
# With BindsTo=, systemd stops the scope the moment this service leaves the
# active state (stop, restart, crash, or failure), and a scope's default
# KillMode=control-group takes the whole tree with it.
#
# NOT After=: a scope ordered after the service that is starting it deadlocks
# the transaction (the scope's start job waits on the service's start job, which
# waits on this ExecStartPre). BindsTo= implies no ordering, which is what we
# want — ExecStop still runs first as part of the service's own stop, so the
# graceful pidfile teardown happens before the cgroup sweep.
exec systemd-run --scope --unit "qcap-${TILE}-$(date +%s)" \
  -p "BindsTo=streamhost@${TILE}.service" \
  -p MemoryMax=3G bash "$LAUNCHER"
