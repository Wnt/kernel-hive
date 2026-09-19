#!/bin/bash
# DRAFT openMSX inner runtime. Outer launcher should follow medley nspawn isolation.
set -euo pipefail
DISP="${MSX_DISPLAY:?}" GEOM="${MSX_GEOM:-1024x768}"
ASSETS="${MSX_ASSETS:-/data/vms/streamhost/assets/msx2}"
WORK=/work N="${DISP#:}"
mkdir -p /tmp/.X11-unix "$WORK/home"; chmod 1777 /tmp/.X11-unix; rm -f "/tmp/.X11-unix/X$N"
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac >"$WORK/xvfb.log" 2>&1 &
export DISPLAY="$DISP" HOME="$WORK/home"
# MEASURE/set the correct openMSX system-data path after the builder install layout is fixed.
MACHINE="${MSX_MACHINE:-Philips_NMS_8250}"
exec "$ASSETS/bin/openmsx" -machine "$MACHINE" -ext msxdos2 -diska "$ASSETS/media/msxdos2.dsk" ${OPENMSX_ARGS:-}
