# shellcheck shell=bash
# vice-native.d/pet2001.sh — host-native conversion stanza for the Commodore
# PET 2001 (1977). Sourced by build-vice-native.sh.
#
# ONE BINARY, TWO STATIONS: xpet serves both this machine and cbm8032, and the
# two share almost nothing — different ROM set, different chargen, different
# keyboard type (graphics US here, business UK there), different surface. The
# ONLY thing that separates them at runtime is `-model`, so it lives in
# VICE_GATE_ARGS / VICE_NATIVE_ARGS and nowhere else, and the two stations get
# their own asset trees so SH_IDLE_PAUSE_PROC_MATCH can tell one `xpet` from
# the other by path.

VICE_EMU=xpet
VICE_DATA_DIRS=(PET)
# The four images `-model 2001` loads (rom1g.vrs names them), plus the external
# palette the model selects — not a .bin, so a *.bin-only staging would miss it
# — plus the GRAPHICS-keyboard symbolic keymap, which is the one this model
# resolves keysyms through. gtk3_grus_sym.vkm, NOT gtk3_sym.vkm.
VICE_ROM_REQUIRED=(
  PET/basic-1.901439-09-05-02-06.bin
  PET/kernal-1.901439-04-07.bin
  PET/edit-1-n.901439-03.bin
  PET/characters-1.901447-08.bin
  PET/rom1g.vrs
  PET/2001-blueish.vpl
  PET/gtk3_grus_sym.vkm
)

# The bridged kiosk's flags minus `-sounddev alsa`. There is no -CRTCborders:
# VICE's CRTC video code has no border option, so the border comes as the
# machine draws it.
VICE_GATE_ARGS=(-model 2001 -CRTCdsize)
# MEASURED off the shm mapping 2026-08-16: 1 327 168 B = 64 + 768*432*4. The
# kiosk's notes said 768x532 for the SDL window; the headless surface is not
# the same thing, which is exactly why this is measured and pinned.
VICE_GEOM_EXPECT=768x432
# A DARK machine: blueish-white text on black, measured 5 390 lit and 8 222
# non-dominant on 331 776 pixels. Floors at ~60 % of measured.
VICE_GATE_FLOOR=3500
VICE_GATE_INK_FLOOR=5000
VICE_GATE_CYCLES=20000000
# Position gate, the cbm2 idea applied to the sibling that also has a fixed
# banner: measured ink bbox rows 16..111, cols 61..433, with slack for the
# blinking cursor.
VICE_GATE_BBOX=8:130:50:450
