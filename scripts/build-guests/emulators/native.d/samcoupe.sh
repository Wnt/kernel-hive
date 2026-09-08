# shellcheck shell=bash
# native.d/samcoupe.sh — host-native conversion stanza for the SAM Coupé,
# the samcoupe wave's `native` stream. Driver samcoupe lives in
# samcoupe/samcoupe.cpp and ships MACHINE_SUPPORTS_SAVE (docs/lab/
# SAMCOUPE-WAVE.md), so no skip-warnings patch is needed and the shared
# launcher's checkpoint restore applies unmodified.

NATIVE_DRIVER=samcoupe
NATIVE_SUBTARGET=samcoupe
NATIVE_SOURCES=src/mame/samcoupe/samcoupe.cpp
NATIVE_GEOM=1024x768
# Device set confirmed on THIS 0.289 build with -listslots/-listmedia
# (2026-09-08): drive1/drive2 both default to slot option "floppy" (SAM
# Coupé Internal Floppy, media flop1/flop2, .mgt/.dsk among the extensions);
# set explicitly so a MAME default change can never silently drop it. No
# mouseport option is attached — this station is keyboard-only (ledger
# OPEN item: no honest absolute-mouse contract for a relative-only device),
# so NATIVE_EXTRA_PATCHES stays empty and no ptr-tags/move-step-cap style
# patch is added.
NATIVE_MAME_ARGS=(-drive1 floppy -drive2 floppy)
NATIVE_EXTRA_PATCHES=()
NATIVE_SKIP_WARNINGS=0

native_stage_roms() {
  local roms="$1"
  # -listxml on this binary shows ONE machine (samcoupe) with 15 BIOS ROM
  # variants (rom01..rom31, atom.z5), all in the maincpu region at offset 0
  # and all optional except the driver's default bios="31" (rom31.z5). No
  # sub-device <rom> entries exist for this driver (unlike apple2e's
  # d2fdc/m68705p3) — confirmed via -listxml samcoupe on this build
  # (2026-09-08).
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" samcoupe /data/assets-staging/samcoupe/roms "$roms" \
    samcoupe
}

# Power-on with no floppy attached is the SAM BASIC screen: a coloured
# copyright banner over a full-screen colour field (not text-on-black like
# mpf2/apple2e — this driver paints a border colour and a title band on
# power-up), so the lit-pixel floor is measured relative to a much busier
# frame than the text-only stations. Measured 2026-09-08 on this build at
# -str 6: 446518 lit pixels (of 786432 total, i.e. most of the screen is
# above the >40 channel threshold — the SAM BASIC field is a solid colour,
# not text-on-black); floor set to 223000, ~half the measured count per the
# brief.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 223000 6
}
