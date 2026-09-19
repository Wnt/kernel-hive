#!/bin/bash
# DRAFT Psion runtime dispatcher for the initial race; final station keeps only the winner.
set -euo pipefail
MODE="${PSION_RUNTIME:-mame}"
BASE="${BASE:-/data/vms/streamhost/stations/psion5}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/psion5}"
case "$MODE" in
  mame)
    export SH_STATION=psion5 SH_CAPTURE=shm SH_INPUT_BACKEND=mamesock SH_AUDIO=off
    export SH_SHM_PATH="$BASE/fb.shm" SH_MAMECTL_SOCK="$BASE/ctl.sock"
    export MAME_NATIVE_BIN="${MAME_NATIVE_BIN:-$ASSETS/mame-native/bin/mame}"
    export MAME_NATIVE_DRIVER=psion5mx MAME_NATIVE_ROMS="${MAME_NATIVE_ROMS:-$ASSETS/roms}"
    export MAME_NATIVE_GEOM="${MAME_NATIVE_GEOM:-640x240}" MAME_NATIVE_CHECKPOINT=0
    exec /path/to/repo/streamhost/stations/mame-native/x11-runtime.sh
    ;;
  windemu)
    : "${DISPLAY:?set DISPLAY from the nspawn/Xvfb outer runtime}"
    exec "${WINDEMU_BIN:-$ASSETS/windemu/windemu}" ${WINDEMU_ARGS:-}
    ;;
  *) echo "unknown PSION_RUNTIME=$MODE" >&2; exit 2 ;;
esac
# MEASURE: actual LCD geometry, pen coordinate range, keyboard map; discard the losing branch.
