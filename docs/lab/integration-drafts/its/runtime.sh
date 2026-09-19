#!/bin/bash
# DRAFT ITS inner runtime. Outer launcher should follow medley nspawn isolation.
set -euo pipefail
DISP="${ITS_DISPLAY:?}" GEOM="${ITS_GEOM:-1024x768}"
ASSETS="${ITS_ASSETS:-/data/vms/streamhost/assets/its}"
WORK=/work PORT="${ITS_PORT:-10004}" N="${DISP#:}"
mkdir -p /tmp/.X11-unix; chmod 1777 /tmp/.X11-unix; rm -f "/tmp/.X11-unix/X$N"
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac >"$WORK/xvfb.log" 2>&1 &
export DISPLAY="$DISP"
cp -a --reflink=auto "$ASSETS/tree" "$WORK/its"
cd "$WORK/its"
[ -x "$ASSETS/start-auto" ] || { echo "missing measured start-auto wrapper; run the lab smoke first" >&2; exit 2; }
"$ASSETS/start-auto" >"$WORK/console.log" 2>&1 &
IPID=$!
for _ in $(seq 1 600); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  kill -0 "$IPID" 2>/dev/null || { tail -100 "$WORK/console.log"; exit 1; }
  sleep .5
done
nc -z 127.0.0.1 "$PORT" || { echo "ITS user terminal not ready" >&2; exit 1; }
exec xterm -geometry 100x32 -fa monospace -fs 16 -e telnet 127.0.0.1 "$PORT"
