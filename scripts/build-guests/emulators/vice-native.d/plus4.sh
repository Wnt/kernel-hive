# shellcheck shell=bash
# vice-native.d/plus4.sh — host-native conversion stanza for the Commodore
# Plus/4. Sourced by build-vice-native.sh; not executable on its own.
#
# The closest sibling to vic20: one binary, no media, no -model flag, cold-boot
# scene, keyboard-only. What is genuinely different is the KEYBOARD, and none of
# it is a builder concern — it is a property of the .vkm the builder stages:
#   * the machine has ONE shift (LSHIFT == RSHIFT in the matrix), and
#   * the exhibit's launcher chord is C= + C, where C= is Tab under VICE's
#     symbolic keymap, and that keymap ALSO delivers the plain letter — the
#     cosmetic leak scripts/build-guests/tiles/plus4.sh documented on the
#     bridged path. Identical here, because it is the SAME keymap file: the
#     conversion changed how a keysym arrives, not how VICE resolves it.
#
# NO ROM PINS BY SHA: VICE carries the Commodore ROMs in its own tree, so the
# pin on the ROMs IS the pin on the fork commit.

VICE_EMU=xplus4
VICE_DATA_DIRS=(PLUS4)
# BASIC + KERNAL are the boot floor; BOTH 3-plus-1 banks are the exhibit itself
# (the office suite is in ROM and is why this station exists); gtk3_sym.vkm is
# the keymap the vicectl KEY verb resolves keysyms through.
VICE_ROM_REQUIRED=(
  PLUS4/basic-318006-01.bin
  PLUS4/kernal-318005-05.bin
  PLUS4/3plus1-317053-01.bin
  PLUS4/3plus1-317054-01.bin
  PLUS4/gtk3_sym.vkm
)

# The bridged kiosk's own flags minus `-sounddev alsa` (the launcher owns audio).
# -TEDdsize is its double-size draw, -TEDborders 0 its full-border framing,
# -pal the machine the station has always been.
VICE_GATE_ARGS=(-pal -TEDdsize -TEDborders 0)
# MEASURED off the shm mapping 2026-08-16: 1 769 536 B = 64 + 768*576*4.
# 384x288 full PAL TED frame at TEDDoubleSize. NOT copied from the kiosk's
# 800x600 X root, which no longer exists.
VICE_GEOM_EXPECT=768x576
# Like the VIC-20 and unlike its four dark siblings, the Plus/4 power-on page is
# WHITE paper (measured 439 036 of 442 368 lit), so "not black" is not a scene
# check here: the ink floor is what proves the banner drew. Measured 321 113
# non-dominant over 224 colours (the CRT filter's blending), against ~none on a
# flat frame.
VICE_GATE_FLOOR=300000
VICE_GATE_INK_FLOOR=200000
VICE_GATE_CYCLES=20000000
