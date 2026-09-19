#!/bin/bash
# DRAFT mvs38 inner runtime. Outer launcher should follow medley nspawn isolation.
set -euo pipefail
DISP="${MVS_DISPLAY:?}" GEOM="${MVS_GEOM:-1024x768}"
ASSETS="${MVS_ASSETS:-/data/vms/streamhost/assets/mvs38}"
WORK=/work N="${DISP#:}"
mkdir -p /tmp/.X11-unix; chmod 1777 /tmp/.X11-unix; rm -f "/tmp/.X11-unix/X$N"
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac >"$WORK/xvfb.log" 2>&1 &
export DISPLAY="$DISP"
cp -a "$ASSETS/tk5/." "$WORK/tk5/"
( cd "$WORK/tk5"; exec ./mvs ) >"$WORK/hercules.log" 2>&1 &
HPID=$!
for _ in $(seq 1 240); do
  nc -z 127.0.0.1 3270 2>/dev/null && break
  kill -0 "$HPID" 2>/dev/null || { tail -80 "$WORK/hercules.log"; exit 1; }
  sleep .5
done
nc -z 127.0.0.1 3270 || { echo "no 3270 listener" >&2; exit 1; }
exec x3270 -model 3279-2 127.0.0.1:3270
