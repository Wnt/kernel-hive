# shellcheck shell=bash
# native.d/riscos3.sh — host-native conversion stanza for RISC OS 3.11 on the
# Acorn Archimedes 310, MAME driver `aa310` (src/mame/acorn/aa310.cpp).
# `aa310` is status="preliminary" in MAME 0.289's own -listxml (measured with
# the system package MAME 0.264, which carries the same driver metadata) so,
# like bbcb, it always shows the "known problems" nag panel — skip-warnings
# is required or the exhibit's rest scene would be that panel forever.
#
# Media: the A310 machine romset (four 0296,0*-02.rom halves, bios=311) plus
# the shared Archimedes keyboard MCU romset — MEASURED good against a system
# MAME 0.264 -verifyroms run, smoke-booted 2026-09-20 to the RISC OS 3.11
# Desktop (icon bar + pointer visible, non-red raster) after pressing a key
# past the preliminary-driver warning. Source: archive.org
# mame-0.264-roms-non-merged (aa310.zip sha256 04d17d96963816721219691857af17
# e6439ae30088ebf2e89fac9d8b12d7194b; archimedes_keyboard.zip sha256
# 1d02b14cd4d2ff80a343c3afb1ba43de0bd77815952816fc19d0736f8644664e) — staged
# under /data/assets-staging/riscos3/, MANIFEST.sha256 there.
#
# Pointer/mouse mapping is UNMEASURED — the aa310 driver exposes the
# Archimedes' own quadrature mouse ports; do not assume the apple2gs ADB
# chain applies. Ship keyboard-first (stream.pointer.transport stays "none")
# until a two-target readback proves a binding, per the integration seed's
# stop condition.

NATIVE_DRIVER=aa310
NATIVE_SUBTARGET=aa310
NATIVE_SOURCES=src/mame/acorn/aa310.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=(-bios 311)
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" aa310 /data/assets-staging/riscos3 "$roms" \
    aa310 archimedes_keyboard
}

# Power-on with the aa310/311 romset reaches the RISC OS 3.11 Desktop: a
# mid-grey raster (mostly non-black) with the icon bar band along the
# bottom. MEASURED 2026-09-20 with system MAME 0.264 (same driver/romset
# metadata as the pinned 0.289): boot completes within ~15s to the Desktop.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 3000 20
}
