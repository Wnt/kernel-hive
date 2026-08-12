# shellcheck shell=bash
# native.d/bbcmicro.sh — host-native conversion stanza for the BBC Micro.
# SOURCES is the acorn DIRECTORY: in 0.289 the BBC family is split across
# several .cpp files off a shared bbc.h and a single-file filter is a
# coin-toss (build-mame-bbcb.sh's lesson). bbcb is "imperfect" (sound), so
# the nag panel exists and skip-warnings is required.
# Romset: sha1-matched from the operator-staged preservation blobs
# (/data/assets-staging/bbcmicro, no authorised URL exists) against THIS
# binary's own listxml — bbcb + the saa5050 teletext glyphs, without which
# MODE 7 draws nothing at all.

NATIVE_DRIVER=bbcb
NATIVE_SUBTARGET=bbcb
NATIVE_SOURCES=src/mame/acorn
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=(-artwork_crop)
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" bbcb /data/assets-staging/bbcmicro "$roms" \
    bbcb saa5050 bbc_acorn8271
}

# Power-on is "BBC Computer 32K / Acorn DFS / BASIC / >" in white MODE 7 on
# black — a non-black floor is the smoke check (operator batch-validates).
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 3000 12
}
