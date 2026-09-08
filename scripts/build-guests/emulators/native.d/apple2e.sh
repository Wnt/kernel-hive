# shellcheck shell=bash
# native.d/apple2e.sh — host-native conversion stanza for the Apple //e
# (enhanced), the apple2e wave's `native` stream. Driver apple2ee lives in
# apple/apple2e.cpp (mpf2's sibling in the same apple/ family). Unlike mpf2
# this driver ships MACHINE_SUPPORTS_SAVE (docs/lab/APPLE2E-WAVE.md), so no
# skip-warnings patch is needed and the shared launcher's checkpoint restore
# applies unmodified.

NATIVE_DRIVER=apple2ee
NATIVE_SUBTARGET=apple2e
NATIVE_SOURCES=src/mame/apple/apple2e.cpp
NATIVE_GEOM=1024x768
# Device set per docs/lab/APPLE2E-WAVE.md (spine, confirmed against stock
# 0.276's -listslots/-listxml on labhost): Apple II Mouse Card in slot 4,
# Disk II NG controller in slot 6 (the driver's own default — set explicitly
# so a MAME default change can never silently drop it), CFFA 2.0 (65C02
# firmware) in slot 7 for the ProDOS hard-disk volume the media stream builds.
NATIVE_MAME_ARGS=(-sl4 mouse -sl6 diskiing -sl7 cffa2)
# The pointer engine's stock binding is hardcoded to the SGI Indy's
# hle_ps2_mouse ioport tags (docs/lab/DEBRIDGE-HANDOVER.md); this station
# needs the env-configurable MAME_CTL_PTR_TAGS/MAME_CTL_BTN_NAMES rebind
# (mame-ctlsock-ptr-tags.patch) to point at the Apple II Mouse Card's
# :sl4:a2mse_button/_x/_y ioports instead.
# ...and two corrections that patch stacks ON TOP of ptr-tags, in this order:
# move-step-cap, because the mouse card's 8-bit accumulator differences its
# field inside a +-0x80 window and one write over 127 counts is read
# BACKWARDS; then open-loop-gain, because this machine has no readable cursor
# register, so MOVEA runs open-loop, the gain learner never fires and the
# module's default 1.0 px/count under-issues by ~40% (measured: 1.547 px per
# count on X, 1.674 on Y). The station fixture sets MAME_CTL_GAIN_X/Y and
# MAME_CTL_SCREEN to match.
# ...and finally home-drain, because the homing slam that opens an open-loop
# session does NOT die against the guest's edge clamp: on the Apple II Mouse
# Card that clamp is in the card's firmware, downstream of an accumulator that
# nets our counts and drains one per MCU read, so the first target's travel is
# spent unwinding the slam and every later target inherits the deficit
# (measured: every landing short by exactly the first target's travel). It
# sizes the slam through the gain and holds the travel for MAME_CTL_HOME_SETTLE
# of device quiet; the station fixture sets that knob.
# ...and last, count-carry, because the open loop rounded twice on every
# move -- the belief by llround(counts * gain) per FIXED-size pacer chunk,
# the wire by llround(Delta-px / gain) -- and a rounding whose operands never
# vary is a bias, not a wash: a second lap of the same five targets in one
# session drifted up to +14 px, every error the same sign. It carries both
# remainders and re-anchors them at every home and restore. Its
# MAME_CTL_REHOME_PX knob (periodic silent re-home) stays off by default.
NATIVE_EXTRA_PATCHES=(mame-ctlsock-ptr-tags.patch mame-ctlsock-move-step-cap.patch mame-ctlsock-open-loop-gain.patch mame-ctlsock-home-drain.patch mame-ctlsock-count-carry.patch)
NATIVE_SKIP_WARNINGS=0

native_stage_roms() {
  local roms="$1"
  # d2fdc (341-0028-a.rom, the Disk II floppy controller's own sequencer
  # PROM) and m68705p3 (bootstrap.bin, the generic MC68705 CPU core's
  # bootstrap ROM the mouse card's MCU sub-device needs) are sub-devices
  # MAME's -listxml does not fold into apple2ee/a2diskiing/a2mouse's own
  # <rom> lists — found only by running the gate and reading its "NOT
  # FOUND" lines (2026-09-08).
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" apple2ee /data/assets-staging/apple2e/roms "$roms" \
    apple2ee a2diskiing a2mouse a2cffa2 d2fdc m68705p3
}

# Power-on with no floppy/hard-disk media attached is the //e's own text
# screen ("Apple //e" banner + a sparse boot-check band) — text on black,
# same non-black smoke gate as mpf2, but the //e's power-on text is much
# sparser than mpf2's colourful BASIC prompt: measured 1376 lit pixels over
# 6 emulated seconds at floor 2000 (2026-09-08), so the floor is lower here.
# The real boot-to-menu proof (ProDOS from the media stream's hive.hdv) is a
# separate framebuffer capture in the native stream's own sandbox rig, not
# this build-time gate.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 1000 6
}
