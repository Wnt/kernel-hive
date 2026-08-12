# shellcheck shell=bash
# native.d/oricatmos.sh — host-native conversion stanza for the Oric Atmos.
# Machine `orica` with -bios ver11; the romset is the single sha1-pinned
# basic11b.rom staged by the operator, matched against this binary's own
# listxml. Driver never nags. The kiosk published an 800x600 root (measured
# 1.6x cheaper to blit); the converted station keeps its geometry.

NATIVE_DRIVER=orica
NATIVE_SUBTARGET=oricatmos
NATIVE_SOURCES=src/mame/tangerine/oric.cpp
NATIVE_GEOM=800x600
NATIVE_MAME_ARGS=(-bios ver11)

native_stage_roms() {
  local roms="$1"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" orica /data/assets-staging/oricatmos "$roms" orica
}

# Power-on is "ORIC EXTENDED BASIC V1.1 / ... / Ready" in black on a WHITE
# page — most of the surface is lit; same high-floor logic as zx81.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 150000 15
}
