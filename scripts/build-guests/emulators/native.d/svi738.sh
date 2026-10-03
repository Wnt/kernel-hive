# shellcheck shell=bash
# Stock Finland/Sweden SVI-738; the MSX1 source also builds its SVI-728 sibling.
NATIVE_DRIVER=svi738sw
NATIVE_SUBTARGET=svi738
NATIVE_SOURCES=src/mame/msx/msx1_v9938.cpp,src/mame/msx/msx1.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=()
NATIVE_EXTRA_PATCHES=()
NATIVE_SKIP_WARNINGS=0
native_stage_roms() {
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" svi738sw /data/assets-staging/svi738/roms "$1" svi738sw
}
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 200000 8
}
