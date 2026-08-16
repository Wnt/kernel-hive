# shellcheck shell=bash
# vice-native.d/vic20.sh — host-native conversion stanza for the Commodore
# VIC-20, the VICE wave's TEMPLATE station (DEBRIDGE-HANDOVER.md, conversion
# order). Sourced by build-vice-native.sh; not executable on its own.
#
# The plainest of the seven: one binary, no media, no model flag, cold-boot
# scene, keyboard-only. Everything below that is NOT `xvic` is shared shape the
# next six inherit.
#
# NO ROM PINS BY SHA, unlike the MAME stanzas: VICE carries the Commodore ROMs
# in its own source tree, so the pin on the ROMs IS the pin on the fork commit.
# What can still go wrong is the staging step silently producing an empty
# directory (`make install` skips data/*/), which is what VICE_ROM_REQUIRED
# catches by name.

VICE_EMU=xvic
VICE_DATA_DIRS=(VIC20)
# The three files the machine cannot boot without, plus the keymap the vicectl
# KEY verb resolves keysyms through — a headless build with no .vkm resolves
# nothing and the exhibit is a dead keyboard with a perfect picture.
VICE_ROM_REQUIRED=(
  VIC20/basic-901486-01.bin
  VIC20/chargen-901460-03.bin
  VIC20/kernal.901486-07.bin
  VIC20/gtk3_sym.vkm
)

# The exhibit's own flags, and the ONLY thing that decides the published
# surface: VICE has no MAME_SHM_SIZE, so the mapping is the emulated screen
# times VICDoubleSize. `-pal` is the machine the station has always been
# (docs/guests/vic20.md); `-VICdsize` is the bridged kiosk's own double-size
# draw; `-VICborders 0` is its full-border framing.
VICE_GATE_ARGS=(-pal -VICdsize -VICborders 0)
# MEASURED by the gate on 2026-08-16, not copied from the kiosk's window table.
VICE_GEOM_EXPECT=896x568
# The power-on screen is WHITE paper inside a cyan border, so every pixel is
# lit — measured 508 928 of 508 928. "Not black" is therefore not a scene
# check on this machine, which is why the ink floor below exists: the border /
# paper / text split leaves 383 477 non-dominant pixels (918 colours, the CRT
# filter's blending), and a flat frame has ~none.
VICE_GATE_FLOOR=300000
VICE_GATE_INK_FLOOR=200000
VICE_GATE_CYCLES=20000000
