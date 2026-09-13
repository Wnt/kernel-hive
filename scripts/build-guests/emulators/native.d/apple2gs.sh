# shellcheck shell=bash
# native.d/apple2gs.sh — host-native conversion stanza for the Apple IIGS
# (ROM 3), the apple2gs wave's `native` stream. Driver `apple2gs` lives in
# src/mame/apple/apple2gs.cpp — the same apple/ family as apple2e, so this
# stanza is apple2e's with the //e-specific expansion cards dropped: the GS
# has its own ADB keyboard/mouse and its own IWM/3.5" drives on the
# motherboard, so the only card it needs is the CFFA 2.0 in slot 7 for the
# ProDOS hard-disk volume GS/OS 6.0.1 boots from.
# apple2gs ships MACHINE_SUPPORTS_SAVE, so no skip-warnings patch is needed
# and the shared launcher's checkpoint restore applies unmodified.

NATIVE_DRIVER=apple2gs
NATIVE_SUBTARGET=apple2gs
NATIVE_SOURCES=src/mame/apple/apple2gs.cpp
NATIVE_GEOM=1024x768
# Device set: CFFA 2.0 (65C02 firmware) in slot 7 carries the 32 MB ProDOS
# volume with GS/OS 6.0.1 + Finder. Nothing else is added — unlike the //e
# the GS's mouse is ADB on the motherboard, and its 3.5"/5.25" drives hang off
# the built-in IWM, so -sl4 mouse / -sl6 diskiing have no equivalent here.
NATIVE_MAME_ARGS=(-sl7 cffa2)
# Pointer: same open-loop ctlsock stack as apple2e (the stock binding is
# hardcoded to the SGI Indy's hle_ps2_mouse ioport tags), rebound via
# MAME_CTL_PTR_TAGS/MAME_CTL_BTN_NAMES onto the GS's ADB mouse ioports. The
# GS's ADB mouse is also a relative device with no readable cursor register,
# so the whole apple2e correction stack applies unchanged in the same order:
# ptr-tags -> move-step-cap -> open-loop-gain -> home-drain -> count-carry.
# The station fixture carries the MEASURED gains; see docs/lab/APPLE2GS-WAVE.md.
# ABS-RAM (last in the chain, authored on macsys1): the GS's ADB mouse is a
# relative device whose counts the Toolbox re-scales, and the SHR raster is
# LETTERBOXED inside the 1024x768 surface (published x 47..976, y 53..717), so
# no open loop can be 1:1 -- a dead-reckoned home is 47/53 px out before any
# gain error. abs-ram states the visitor's pixel in the guest's own cursor
# globals over the CPU program space instead, and brings the PEEK/POKEW/POKEB
# probe verbs the binding has to be DERIVED with. Env-only: unset, the binary
# behaves exactly as the open-loop chain did.
# RAM-CURSOR (last in the chain, authored here): the GS's cursor position IS
# readable -- $E1/00E9 (X) and $E1/00EB (Y), 16-bit LE, guest px -- but it is
# an OUTPUT: poking it sticks and never redraws, and the next ADB poll
# republishes it from an accumulator that is nowhere in banks $00/$01/$E0/$E1
# nor in the ADB micro's RAM. So the macsys1 abs-ram WRITE route does not
# transfer; the READ loop does. mame-ctlsock-ram-cursor.patch lets a
# MAME_CTL_CURSOR_ITEMS entry address INSIDE a save item
# (`m_megaii_ram@0x100E9:2` -- m_megaii_ram is size=1 count=131072 over
# $E0/$E1) and adds MAME_CTL_CAL_SX/SY so a GUEST-pixel reading becomes a
# PUBLISHED one (47 + gx*1.4531, 53 + gy*3.325). abs-ram stays in the chain
# for its PEEK/POKEW/POKEB probe verbs, which is what the binding was derived
# with. Both are env-only.
NATIVE_EXTRA_PATCHES=(mame-ctlsock-ptr-tags.patch mame-ctlsock-move-step-cap.patch mame-ctlsock-open-loop-gain.patch mame-ctlsock-home-drain.patch mame-ctlsock-count-carry.patch mame-ctlsock-abs-ram.patch mame-ctlsock-ram-cursor.patch)
NATIVE_SKIP_WARNINGS=0

native_stage_roms() {
  local roms="$1"
  # Sub-device ROMs -listxml does not fold into apple2gs/a2cffa2's own <rom>
  # lists are found by running the gate and reading its "NOT FOUND" lines.
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" apple2gs /data/assets-staging/apple2gs/roms "$roms" \
    apple2gs a2cffa2
}

# Power-on with no bootable media attached fills the ENTIRE published surface:
# the GS's super-hi-res desktop is a solid blue raster behind the "Check startup
# device!" line, so unlike the //e's sparse text band this machine lights every
# pixel. MEASURED 2026-09-13: 786432 lit pixels = 1024*768, the whole surface.
# A copied floor of 1000 would therefore pass on almost any failure; the floor
# here is most of the raster. The real scene proof (the GS/OS 6.0.1 Finder
# desktop from the CFFA 2.0 volume) is a separate framebuffer capture in the
# wave's own rig -- docs/lab/APPLE2GS-WAVE.md -- not this build-time gate,
# because the gate runs with no -hard1 media.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 700000 10
}
