# shellcheck shell=bash
# native.d/zx81.sh — host-native conversion stanza for the Sinclair ZX81.
# -bios 2nd (the improved ROM) and -ramsize 1K are the exhibit's identity;
# the romset is the single sha1-pinned zx81a.rom staged by the operator,
# matched against this binary's own listxml. Driver never nags.

NATIVE_DRIVER=zx81
NATIVE_SUBTARGET=zx81
NATIVE_SOURCES=src/mame/sinclair/zx.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=(-bios 2nd -ramsize 1K)

native_stage_roms() {
  local roms="$1"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" zx81 /data/assets-staging/zx81 "$roms" zx81
}

# Power-on is a WHITE field with one inverse-video K — nearly the whole
# surface is lit, so the floor is high on purpose: a black/stalled frame and
# a missing-ROM abort both read ~0.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 200000 12
}
