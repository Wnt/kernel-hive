# shellcheck shell=bash
# vice-native.d/cbm2.sh — host-native conversion stanza for the Commodore
# CBM 610 (CBM-II / B-series, 6509). Sourced by build-vice-native.sh.
#
# Mechanical, with one thing worth carrying over from the bridged builder: its
# readiness gate was POSITION-based, not count-based, because the failure it
# had to catch was a window drawn at the wrong offset and silently clipped by
# the X root. There is no X root any more, but the check is still the only one
# that can tell a correctly framed banner from a misframed one, so it survives
# as VICE_GATE_BBOX below.
#
# NOT a near-duplicate of cbm8032 despite the same green 80-column banner —
# see the station's museum placard.

VICE_EMU=xcbm2
VICE_DATA_DIRS=(CBM-II)
# A 610 is the 128 KB LOW-PROFILE model, which VICE resolves through
# rom128l.vrs to exactly these three images (a 710 would take chargen-901232-01
# instead), plus the keymap the vicectl KEY verb resolves keysyms through.
VICE_ROM_REQUIRED=(
  CBM-II/basic-901242+3-04a.bin
  CBM-II/kernal-901244-04a.bin
  CBM-II/chargen-901237-01.bin
  CBM-II/rom128l.vrs
  CBM-II/gtk3_sym.vkm
)

# The bridged kiosk's flags minus `-sounddev alsa`. NO -CRTCdsize, and now for a
# better reason than the kiosk had: the kiosk dropped it because the doubled
# 1408x1056 window did not fit an 800x600 X root. Host-native there is no root
# at all, so the native surface simply IS the stream — same glyph size the
# visitor sees today, at a quarter of the encode cost of doubling.
VICE_GATE_ARGS=(-model 610 -pal)
# MEASURED off the shm mapping 2026-08-16: 1 498 176 B = 64 + 704*532*4.
VICE_GEOM_EXPECT=704x532
# A DARK machine: green text on black, measured 1 649 lit and 3 031
# non-dominant on a 374 528-pixel surface. Both floors are therefore small, and
# they are not redundant — "lit" counts pixels above the brightness threshold,
# "non-dominant" also counts the CRT filter's near-black blend pixels around
# every glyph. Floors sit at ~60 % of measured.
VICE_GATE_FLOOR=1000
VICE_GATE_INK_FLOOR=1800
VICE_GATE_CYCLES=20000000
# THE POSITION GATE, kept from the bridged builder. Measured ink bbox is
# rows 65..145, cols 31..296 (banner, "ready." and the cursor). Containment
# with slack, not equality: the cursor blinks, so the bottom edge moves.
VICE_GATE_BBOX=55:170:20:320
