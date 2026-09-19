#!/bin/bash
# DRAFT Genera inner runtime. Outer launcher should follow medley nspawn isolation.
set -euo pipefail
DISP="${GENERA_DISPLAY:?}" GEOM="${GENERA_GEOM:-1280x1024}"
ASSETS="${GENERA_ASSETS:-/data/vms/streamhost/assets/genera}"
WORK=/work N="${DISP#:}"
mkdir -p /tmp/.X11-unix "$WORK/home"; chmod 1777 /tmp/.X11-unix; rm -f "/tmp/.X11-unix/X$N"
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac >"$WORK/xvfb.log" 2>&1 &
export DISPLAY="$DISP" HOME="$WORK/home"
cp -a "$ASSETS/runtime/." "$WORK/runtime/"
cp -f "$ASSETS/dot.VLM" "$HOME/.VLM"
[ -d "$ASSETS/fonts" ] && { xset fp+ "$ASSETS/fonts" || true; xset fp rehash || true; }
xmodmap -e 'keysym Alt_L = Meta_L Alt_L' || true
xmodmap -e 'add mod1 = Meta_L' || true
cd "$WORK/runtime"
exec "$ASSETS/bin/genera"
# MEASURE: exact world/FEP path references, required X fonts, modifier map and pristine-world reset copy set.
