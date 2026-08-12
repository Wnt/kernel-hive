# shellcheck shell=bash
# native.d/mpf2.sh — host-native conversion stanza for the Multitech
# Micro-Professor II. De-bridging IS this station's fix: its trixie rollback
# was a second-cold-boot kiosk/getty failure, and host-native has no kiosk,
# no getty, no guest. Driver mpf2 lives in apple/tk2000.cpp (it is an
# Apple II-family machine); the driver nags, so skip-warnings is required.

NATIVE_DRIVER=mpf2
NATIVE_SUBTARGET=mpf2
NATIVE_SOURCES=src/mame/apple/tk2000.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=()
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" mpf2 /data/assets-staging/mpf2 "$roms" mpf2
}

# Power-on is the MPF-II BASIC screen — text on black; non-black floor.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 2000 12
}
