#!/bin/bash
# DRAFT NP2kai inner runtime. Outer launcher should follow vision/medley nspawn isolation.
set -euo pipefail
DISP="${PC98_DISPLAY:?}" GEOM="${PC98_GEOM:-1024x768}"
ASSETS="${PC98_ASSETS:-/data/vms/streamhost/assets/pc98}"
WORK=/work N="${DISP#:}"
mkdir -p /tmp/.X11-unix "$WORK/home/.config"; chmod 1777 /tmp/.X11-unix; rm -f "/tmp/.X11-unix/X$N"
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac >"$WORK/xvfb.log" 2>&1 &
export DISPLAY="$DISP" HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config"
cp --reflink=auto -f "$ASSETS/disk-seed.hdi" "$WORK/disk.hdi"
cp -a "$ASSETS/bios/." "$WORK/home/"
[ -f "$ASSETS/np2kai.cfg" ] && cp -f "$ASSETS/np2kai.cfg" "$WORK/home/.config/np2kai.cfg"
cd "$WORK"
exec "$ASSETS/bin/sdlnp21kai" ${NP2_ARGS:-}
# MEASURE actual config path/name and HDD path syntax on the pinned build; bake them into the final fixture.
