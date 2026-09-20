#!/bin/bash
# DRAFT MAME-native Kaypro runtime; final station uses shared mame-native/x11-runtime.sh.
set -euo pipefail
BASE="${BASE:-/data/vms/streamhost/stations/cpm22}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/cpm22}"
export SH_STATION=cpm22 SH_CAPTURE=shm SH_INPUT_BACKEND=mamesock SH_AUDIO=off
export SH_SHM_PATH="$BASE/fb.shm" SH_MAMECTL_SOCK="$BASE/ctl.sock"
export MAME_NATIVE_BIN="${MAME_NATIVE_BIN:-$ASSETS/mame-native/bin/mame}"
export MAME_NATIVE_DRIVER=kaypro2 MAME_NATIVE_ROMS="${MAME_NATIVE_ROMS:-$ASSETS/roms}"
export MAME_NATIVE_GEOM="${MAME_NATIVE_GEOM:-1024x768}" MAME_NATIVE_CHECKPOINT=0
ARGS="-flop1 $ASSETS/disks/system.img"
[ -f "$ASSETS/disks/wordstar.img" ] && ARGS="$ARGS -flop2 $ASSETS/disks/wordstar.img"
export MAME_NATIVE_ARGS="$ARGS"
# MEASURE actual SHM geometry and key pacing; no pointer path.
exec /path/to/repo/streamhost/stations/mame-native/x11-runtime.sh
