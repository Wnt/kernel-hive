# shellcheck shell=bash
# native.d/msx2.sh — host-native conversion stanza for MSX2, the msx2 wave's
# `native` stream (record wave 2026-09-21, issue #60). Driver nms8250 (a
# stock Philips NMS 8250, ordinary MSX2 with one internal WD2793 floppy
# drive) lives in msx/msx2.cpp — the integration seed's exact machine choice,
# chosen over openMSX per AGENTS.md rule 13 (host-native beats a kiosk/build
# PoC) since MAME already ships this driver and the box already builds MAME
# host-native for every other MSX-adjacent 8-bit station (samcoupe,
# atari800xl, apple2e).

NATIVE_DRIVER=nms8250
NATIVE_SUBTARGET=msx2
NATIVE_SOURCES=src/mame/msx/msx2.cpp
NATIVE_GEOM=1024x768
# Device set per -listslots/-listmedia nms8250 on this 0.289 build
# (2026-09-20): ONE internal floppy drive (-flop1, WD2793, media
# .dsk/.mfi/.hfe/...), two cartridge slots left EMPTY (this exhibit is
# disk-based, not cartridge-based), no mouseport option attached — keyboard-
# only exhibit (stream.pointer.transport stays "none"). The boot-gate build
# runs with -flop1 empty; the media stream's MSX-DOS2 boot disk is wired in
# via station.env's MAME_NATIVE_ARGS at runtime, matching the atari800xl
# pattern (disk path is a runtime concern, not a build-time one).
NATIVE_MAME_ARGS=()
NATIVE_EXTRA_PATCHES=()
NATIVE_SKIP_WARNINGS=0

native_stage_roms() {
  local roms="$1"
  # nms8250 BIOS set (4 members: main + sub + kanji + disk BIOS) staged from
  # archive.org item mame-0.264-roms-non-merged (non-merged set, individual
  # files) at /data/assets-staging/msx2/roms/nms8250.zip, matched to this
  # binary's own -listxml by SHA1 (stage-romset.py), never a filename guess.
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" nms8250 /data/assets-staging/msx2/roms "$roms" \
    nms8250
}

# Power-on with no floppy (cold boot, no disk drive to error-loop on, unlike
# the Atari SIO chain) reaches MSX-BASIC's "Ok" prompt directly on a solid
# blue SCREEN 0 field (V9938 default text-mode background) — a BUSY frame
# like samcoupe's, not a text-on-black one, because the whole background is
# above the >40 channel threshold. MEASURED 2026-09-20 on this build at
# -str 6: 684126 lit pixels (of 786432 total); floor set to 340000, ~half
# the measured count per the fleet convention. Smoke stream (same day)
# confirmed the SAME frame reappears with the MSX-DOS 2 boot disk attached
# via -flop1 — the machine still lands on MSX-BASIC's "Ok", not an
# auto-boot into MSX-DOS 2 (see docs/lab/MSX2-WAVE.md, "rest scene").
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 340000 6
}
