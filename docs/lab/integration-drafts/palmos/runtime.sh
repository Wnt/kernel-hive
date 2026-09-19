#!/bin/bash
# DRAFT MAME-native Palm runtime; use only if MAME wins.
set -euo pipefail
BASE="${BASE:-/data/vms/streamhost/stations/palmos}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/palmos}"
export SH_STATION=palmos SH_CAPTURE=shm SH_INPUT_BACKEND=mamesock SH_AUDIO=off
export SH_SHM_PATH="$BASE/fb.shm" SH_MAMECTL_SOCK="$BASE/ctl.sock"
export MAME_NATIVE_BIN="${MAME_NATIVE_BIN:-$ASSETS/mame-native/bin/mame}"
export MAME_NATIVE_DRIVER="${PALM_DRIVER:-palmiii}"
export MAME_NATIVE_ROMS="${MAME_NATIVE_ROMS:-$ASSETS/roms}"
export MAME_NATIVE_GEOM="${MAME_NATIVE_GEOM:-320x480}"
export MAME_NATIVE_CHECKPOINT=0 MAME_NATIVE_STANDBY_DELAY_S=5
# MEASURE: orientation, pen X/Y tags/ranges, pen-down field. No relative pointer.
exec /path/to/repo/streamhost/stations/mame-native/x11-runtime.sh
