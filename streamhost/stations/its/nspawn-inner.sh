#!/bin/bash
# =============================================================================
# stations/its/nspawn-inner.sh — PID 2 INSIDE the its container.
#
# Started by x11-runtime.sh as the command of `systemd-nspawn --as-pid2`.
# It owns the whole visitor-visible stack:
#
#   1. the station's own Xvfb on the pinned display (its socket dir is the
#      host-side /run/streamhost/x11/its bound over /tmp/.X11-unix, so the
#      daemon's x11 capture and XTEST input are unchanged);
#   2. the SIMH PDP-10 (KS10) running ITS, with its simulator console going to
#      a logfile — the console carries daemon spam and a `sim>` escape prompt
#      and is NEVER part of the museum surface;
#   3. a real TCP probe of the ITS user terminal (DZ11 line 0, port 10004);
#   4. the visitor surface: one xterm telnetted to that line, exec'd in this
#      script's place so its exit ends the container.
#
# Writable state is /work only: the pristine rp0.dsk was copied there by the
# outer launcher before this script ran, and the simulator config written here
# attaches THAT copy. The built ITS tree stays read-only, so a visitor who
# reaches DDT can never touch the seed.
# =============================================================================
set -euo pipefail

DISP="${SH_X11_DISPLAY:?}"
GEOM="${ITS_GEOM:-1024x768}"
TREE="${ITS_TREE:?}"
PORT="${ITS_PORT:-10004}"
COLS="${ITS_COLS:-80}"
ROWS="${ITS_ROWS:-30}"
FONTSIZE="${ITS_FONTSIZE:-21}"
READY_TIMEOUT="${ITS_READY_TIMEOUT_S:-300}"
WORK=/work

chmod 1777 /tmp/.X11-unix 2>/dev/null || true
rm -f "/tmp/.X11-unix/X${DISP#:}"

Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac \
  >"$WORK/xvfb.log" 2>&1 &
XPID=$!
for _ in $(seq 1 100); do
  [ -S "/tmp/.X11-unix/X${DISP#:}" ] && break
  kill -0 "$XPID" 2>/dev/null || {
    echo "its-inner: Xvfb died:" >&2
    cat "$WORK/xvfb.log" >&2
    exit 1
  }
  sleep 0.1
done
[ -S "/tmp/.X11-unix/X${DISP#:}" ] || {
  echo "its-inner: no X socket after 10 s" >&2
  exit 1
}
export DISPLAY="$DISP"

# --- the simulator config. Written here, not taken from the read-only tree,
# because the tree's out/simh/boot attaches the SEED disk by a relative path.
# Chaosnet/GT40/VT52 lines from the upstream config are dropped: the station
# publishes exactly one terminal.
[ -f "$WORK/rp0.dsk" ] || {
  echo "its-inner: no writable disk at $WORK/rp0.dsk (outer launcher did not seed work/)" >&2
  exit 1
}
cat >"$WORK/boot" <<CONF
set console wru=034
set cpu its
set cpu idle
set tim y2k
set dz 8b lines=8
at -u dz0 $PORT
set rp0 rp06
at rp0 $WORK/rp0.dsk
b rp0
CONF

cd "$WORK"
"$TREE/tools/simh/BIN/pdp10" "$WORK/boot" >"$WORK/console.log" 2>&1 </dev/null &
SPID=$!

deadline=$(($(date +%s) + READY_TIMEOUT))
until nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
  kill -0 "$SPID" 2>/dev/null || {
    echo "its-inner: simulator exited before the user terminal came up" >&2
    tail -40 "$WORK/console.log" >&2 || true
    exit 1
  }
  [ "$(date +%s)" -lt "$deadline" ] || {
    echo "its-inner: port $PORT never opened" >&2
    tail -40 "$WORK/console.log" >&2 || true
    exit 1
  }
  sleep 0.25
done

# The museum surface. No window manager runs, so xterm maps itself at +0+0 at
# exactly this size; the rest of the root window stays black.
exec xterm -display "$DISP" -geometry "${COLS}x${ROWS}+0+0" \
  -fa "DejaVu Sans Mono" -fs "$FONTSIZE" -bg black -fg white -cr white \
  -b 0 -bw 0 +sb -title "MIT ITS" \
  -xrm 'xterm*backarrowKey: false' -xrm 'xterm*metaSendsEscape: true' \
  -e telnet 127.0.0.1 "$PORT"
