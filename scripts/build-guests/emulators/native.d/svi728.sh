# shellcheck shell=bash
# International SVI-728, MSX1 BASIC in ROM; no disk expansion fitted.
NATIVE_DRIVER=svi728
NATIVE_SUBTARGET=svi728
NATIVE_SOURCES=src/mame/msx/msx1.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=()
NATIVE_EXTRA_PATCHES=()
NATIVE_SKIP_WARNINGS=0
native_stage_roms() {
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" svi728 /data/assets-staging/svi728/roms "$1" svi728
}
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 200000 8
}
