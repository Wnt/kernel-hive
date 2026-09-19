#!/bin/bash
# DRAFT Multics inner runtime. Outer launcher should copy medley's nspawn security shape.
set -euo pipefail
DISP="${MULTICS_DISPLAY:?}" GEOM="${MULTICS_GEOM:-1024x768}"
ASSETS="${MULTICS_ASSETS:-/data/vms/streamhost/assets/multics}"
WORK=/work PORT="${MULTICS_PORT:-6180}" N="${DISP#:}"
mkdir -p /tmp/.X11-unix; chmod 1777 /tmp/.X11-unix; rm -f "/tmp/.X11-unix/X$N"
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac >"$WORK/xvfb.log" 2>&1 &
export DISPLAY="$DISP"
cp -a "$ASSETS/quickstart/." "$WORK/quickstart/"
cd "$WORK/quickstart"
"$ASSETS/bin/dps8" MR12.8_boot.ini >"$WORK/dps8.log" 2>&1 &
DPID=$!
for _ in $(seq 1 600); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  kill -0 "$DPID" 2>/dev/null || { tail -100 "$WORK/dps8.log"; exit 1; }
  sleep .5
done
nc -z 127.0.0.1 "$PORT" || { echo "terminal port not ready" >&2; exit 1; }
exec xterm -geometry 100x32 -fa monospace -fs 16 -e telnet 127.0.0.1 "$PORT"
