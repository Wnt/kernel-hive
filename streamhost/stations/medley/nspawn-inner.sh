#!/bin/bash
# =============================================================================
# stations/medley/nspawn-inner.sh — PID 2 INSIDE the medley container.
#
# Started by x11-runtime.sh as the command of `systemd-nspawn --as-pid2`, so
# this script is the container's payload: it starts the station's own Xvfb on
# the pinned display (whose socket directory is the host-side
# /run/streamhost/x11/<tile>, bind-mounted over /tmp/.X11-unix), waits for the
# socket, then execs maiko in its place. When maiko exits the stub init exits
# and the whole container — Xvfb included — is gone; that is what makes
# "reset = relaunch" one kill from outside.
#
# Everything this script can see is what x11-runtime.sh bound in: the maiko
# binary and the Medley tree read-only, work/ read-write, the socket dir.
# It runs as the container's root, which is an unprivileged uid on the host
# (--private-users), with CAP_SYS_ADMIN dropped and the mount syscalls
# filtered — see docs/guests/medley.md §Security for the proof list.
# =============================================================================
set -euo pipefail

DISP="${SH_X11_DISPLAY:?}"
GEOM="${MEDLEY_GEOM:-1024x768}"
MEM="${MEDLEY_MEM:-256}"
SYSOUT="${LDESRCESYSOUT:?}"
BIN="${MEDLEY_BIN:?}"
WORK="${HOME:?}"

# The bind-mounted socket dir arrives owned by the host; X wants 1777.
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
rm -f "/tmp/.X11-unix/X${DISP#:}"

Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac \
  >"$WORK/xvfb.log" 2>&1 &
XPID=$!
for _ in $(seq 1 100); do
  [ -S "/tmp/.X11-unix/X${DISP#:}" ] && break
  kill -0 "$XPID" 2>/dev/null || {
    echo "medley-inner: Xvfb died:" >&2
    cat "$WORK/xvfb.log" >&2
    exit 1
  }
  sleep 0.1
done
[ -S "/tmp/.X11-unix/X${DISP#:}" ] || {
  echo "medley-inner: no X socket after 10 s" >&2
  exit 1
}

export DISPLAY="$DISP"
cd "$WORK"
# The argument shape is run-medley's: -g is the X window, -sc the Lisp
# screen; equal and 4:3 so the capture is identity-mapped.
exec "$BIN" -display "$DISP" -noscroll -g "$GEOM" -sc "$GEOM" \
  -title "Medley Interlisp" -m "$MEM" "$SYSOUT"
