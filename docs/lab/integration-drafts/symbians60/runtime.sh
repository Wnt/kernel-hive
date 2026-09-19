#!/bin/bash
# DRAFT Symbian inner runtime. Outer launcher should follow medley nspawn isolation.
set -euo pipefail
DISP="${SYMBIAN_DISPLAY:?}" GEOM="${SYMBIAN_GEOM:-720x900}"
ASSETS="${SYMBIAN_ASSETS:-/data/vms/streamhost/assets/symbians60}"
WORK=/work N="${DISP#:}"
mkdir -p /tmp/.X11-unix; chmod 1777 /tmp/.X11-unix; rm -f "/tmp/.X11-unix/X$N"
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac >"$WORK/xvfb.log" 2>&1 &
export DISPLAY="$DISP"
rm -rf "$WORK/device"; cp -a "$ASSETS/device-seed" "$WORK/device"
EKA_BIN="${EKA_BIN:-$ASSETS/eka2l1/eka2l1_qt}"
[ -x "$EKA_BIN" ] || { echo "missing EKA2L1 binary" >&2; exit 1; }
# MEASURE EKA2L1 CLI on the pinned build. Put the proven data-dir/device args in EKA_ARGS.
exec "$EKA_BIN" ${EKA_ARGS:-}
