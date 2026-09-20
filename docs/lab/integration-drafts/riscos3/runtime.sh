#!/bin/bash
# DRAFT MAME-native runtime knobs. Final station uses shared mame-native/x11-runtime.sh.
set -euo pipefail
BASE="${BASE:-/data/vms/streamhost/stations/riscos3}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/riscos3}"
export SH_STATION=riscos3 SH_CAPTURE=shm SH_INPUT_BACKEND=mamesock SH_AUDIO=off
export SH_SHM_PATH="$BASE/fb.shm" SH_MAMECTL_SOCK="$BASE/ctl.sock"
export MAME_NATIVE_BIN="${MAME_NATIVE_BIN:-$ASSETS/mame-native/bin/mame}"
export MAME_NATIVE_DRIVER=aa310
export MAME_NATIVE_ROMS="${MAME_NATIVE_ROMS:-$ASSETS/roms}"
export MAME_NATIVE_GEOM="${MAME_NATIVE_GEOM:-1024x768}"
export MAME_NATIVE_ARGS="-bios 311"
export MAME_NATIVE_CHECKPOINT=0
export MAME_NATIVE_STANDBY_DELAY_S=8
# MEASURE before promotion: actual SHM geometry, mouse port tags/range, 3-button semantics, keymap.
exec /path/to/repo/streamhost/stations/mame-native/x11-runtime.sh
