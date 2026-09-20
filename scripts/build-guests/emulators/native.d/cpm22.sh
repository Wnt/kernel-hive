# shellcheck shell=bash
# native.d/kayproii.sh — host-native conversion stanza for the Kaypro II, the
# cpm22 wave's `native` stream. Driver `kayproii` lives in
# src/mame/kaypro/kaypro.cpp (MACHINE_SUPPORTS_SAVE — see the COMP() line for
# kayproii), so no skip-warnings patch is needed and the shared launcher's
# checkpoint restore applies unmodified.
#
# IMPORTANT correction on the integration seed: the driver short name is
# `kayproii`, NOT `kaypro2` as docs/lab/integration-seeds/cpm22.md guessed —
# confirmed with -listxml against a stock MAME 0.276 system package on
# labhost (2026-09-20). `kaypro2` is only the FLOPPY FORMAT's internal name
# (formats/kaypro_dsk.cpp's kayproii_format::name()), not a driver.

NATIVE_DRIVER=kayproii
NATIVE_SUBTARGET=kayproii
NATIVE_SOURCES=src/mame/kaypro/kaypro.cpp
NATIVE_GEOM=1024x768
# Device set: default bios "149" (81-149.u47, board 81-110, CRC 28264bc1) has
# no surviving dump on the mirrors checked 2026-09-20 (retroarchive.org/
# maslin/roms/kaypro/ only carries 149b/149c); ship bios=149c, the same
# revision archive.org's dedicated "81149c_KayproII_ROM" item preserves, on
# the SAME 81-110 board family as the default. NATIVE_MAME_ARGS carries it so
# every launch (builder gate, smoke rig, production fixture) agrees.
NATIVE_MAME_ARGS=(-bios 149c)
NATIVE_EXTRA_PATCHES=()
NATIVE_SKIP_WARNINGS=0

native_stage_roms() {
  local roms="$1"
  # CORRECTED 2026-09-20 after building the actual fleet-pinned mame0289
  # binary: on THIS tree the keyboard device is `kayproiikbd`
  # (devices/bus/keytronic/keytronic_l2207.cpp, an Intel i8048 HLE) needing
  # `kaypro_ii-ins8048.bin` (1024 bytes, CRC f65e1ca5, sha1
  # 7919385fe8badbb610b793a3f5e4077982094aaa) — NOT `kaypro10kbd`/
  # `m5l8049.bin`, which is what a STOCK MAME 0.276 SYSTEM PACKAGE (used
  # only for the early smoke proof, see docs/lab/CPM22-WAVE.md) resolves to.
  # Different MAME trees renamed this device between versions; always trust
  # -listxml on the BINARY THAT WILL ACTUALLY RUN, never an earlier smoke
  # test on a different build. Two romsets feed this scene: kayproii.zip
  # itself (81-149c.u47 BIOS + 81-146.u43 chargen) and the device romset
  # kayproiikbd.zip (kaypro_ii-ins8048.bin).
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" kayproii /data/assets-staging/cpm22/roms "$roms" \
    kayproii kayproiikbd
}

# Power-on with no floppy attached is the "* KAYPRO II *  Please place your
# diskette into Drive" banner, green text on a black field — text-only, so
# the lit-pixel floor is set low like the other text-console MAME stations
# (apple2e/mpf2), not the SAM Coupé's solid-colour floor. MEASURED 2026-09-20
# on a stock MAME 0.276 package (bios=149c): that banner alone already lights
# well above a few thousand px on the 560x240 raster; keep the fleet's
# conservative floor of 4000 lit pixels the same as the other 80-column
# text-console conversions.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 4000 6
}
