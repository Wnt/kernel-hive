# shellcheck shell=bash
NATIVE_DRIVER=svi328
NATIVE_SUBTARGET=svi328
NATIVE_SOURCES=src/mame/svi/svi318.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=(-bios v111)
NATIVE_EXTRA_PATCHES=()
NATIVE_SKIP_WARNINGS=0

native_stage_roms() {
  local source="${SVI_ROM_SOURCE:-/data/assets-staging/svi328/roms}"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" svi328 "$source" "$1" svi328
}

native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 20000 6
}
