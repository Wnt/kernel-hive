# shellcheck shell=bash
# vice-native.d/cbm8032.sh — host-native conversion stanza for the Commodore
# CBM 8032. Sourced by build-vice-native.sh.
#
# Same `xpet` binary as pet2001 and almost nothing else in common: BASIC 4.0
# instead of BASIC 1, an 80-column business editor instead of the 40-column
# graphics one, a different chargen, and a BUSINESS-UK keyboard whose matrix
# shares no layout with the 2001's graphics keyboard. `-model` is the whole
# difference and it lives in the args.
#
# THIS CONVERSION RETIRES THE WAVE'S 1600x1200 X ROOT. The bridged kiosk grew
# its root to 1600x1200 purely to CONTAIN VICE's fixed 1408x1064 SDL window
# (fullscreen renders black under std-VGA capture), and streamhost then encoded
# all 1600x1200 of it — mostly black margin. Host-native there is no root: the
# published surface is the emulated screen and nothing else, 1408x1088,
# which is 36 % fewer pixels to encode with no loss of picture.

VICE_EMU=xpet
VICE_DATA_DIRS=(PET)
# The four images `-model 8032` loads (src/pet/petmodel.c: RAM_32K, COLS_80,
# KBD_TYPE_BUSINESS_UK, resolved through src/pet/petrom.h), plus the
# BUSINESS-UK symbolic keymap this model resolves keysyms through —
# gtk3_buuk_sym.vkm, NOT the 2001's gtk3_grus_sym.vkm and not gtk3_sym.vkm.
VICE_ROM_REQUIRED=(
  PET/basic-4.901465-23-20-21.bin
  PET/kernal-4.901465-22.bin
  PET/edit-4-80-b-50Hz.901474-04_.bin
  PET/characters-2.901447-10.bin
  PET/gtk3_buuk_sym.vkm
)

# The bridged kiosk's flags minus `-sounddev alsa`. -CRTCdsize is kept: at
# native size an 80x25 CRTC screen is 704x544 and the glyphs are half the size
# the exhibit has always shown. There is no -CRTCborders (VICE's CRTC video
# code has none; asking for it is a hard parse error, not a no-op).
VICE_GATE_ARGS=(-model 8032 -CRTCdsize)
# MEASURED off the shm mapping 2026-08-16: 6 127 680 B = 64 + 1408*1088*4.
VICE_GEOM_EXPECT=1408x1088
# A DARK machine: green text on black, measured 8 322 lit and 15 268
# non-dominant on 1 531 904 pixels — a scene that fills 1 % of a large surface,
# which is why a percentage-of-frame floor would be useless here and an
# absolute one is not. Floors at ~60 % of measured.
VICE_GATE_FLOOR=5000
VICE_GATE_INK_FLOOR=9000
VICE_GATE_CYCLES=20000000
# Position gate: measured ink bbox rows 90..302, cols 61..497, with slack for
# the blinking cursor. This one earns its keep twice — the bridged builder
# recorded that for ~2 s after xpet starts the CRTC paints all 2000 cells of
# uninitialised RAM as random glyphs, and that frame fails containment.
VICE_GATE_BBOX=70:340:45:540
