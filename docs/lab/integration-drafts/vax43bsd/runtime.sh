#!/bin/bash
# DRAFT VAX/SIMH inner runtime. Outer launcher should follow medley nspawn isolation.
set -euo pipefail
DISP="${VAX_DISPLAY:?}" GEOM="${VAX_GEOM:-1024x768}"
ASSETS="${VAX_ASSETS:-/data/vms/streamhost/assets/vax43bsd}"
WORK=/work PORT="${VAX_TTY_PORT:-8888}" N="${DISP#:}"
mkdir -p /tmp/.X11-unix; chmod 1777 /tmp/.X11-unix; rm -f "/tmp/.X11-unix/X$N"
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac >"$WORK/xvfb.log" 2>&1 &
export DISPLAY="$DISP"
cp --reflink=auto -f "$ASSETS/media/bsd43-ra81.dsk" "$WORK/bsd43-ra81.dsk"
cp -f "$ASSETS/boot.ini" "$WORK/boot.ini"
( cd "$WORK"; exec "$ASSETS/bin/vax780" boot.ini ) >"$WORK/simh.log" 2>&1 &
SPID=$!
for _ in $(seq 1 600); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  kill -0 "$SPID" 2>/dev/null || { tail -100 "$WORK/simh.log"; exit 1; }
  sleep .5
done
nc -z 127.0.0.1 "$PORT" || { echo "DZ terminal not ready" >&2; exit 1; }
exec xterm -geometry 100x32 -fa monospace -fs 16 -e telnet 127.0.0.1 "$PORT"
