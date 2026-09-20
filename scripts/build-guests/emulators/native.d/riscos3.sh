# shellcheck shell=bash
# native.d/riscos3.sh — host-native conversion stanza for RISC OS 3.11 on the
# Acorn Archimedes 310, MAME driver `aa310` (src/mame/acorn/aa310.cpp).
# `aa310` is status="preliminary" in MAME 0.289's own -listxml (measured with
# the system package MAME 0.264, which carries the same driver metadata) so,
# like bbcb, it always shows the "known problems" nag panel — skip-warnings
# is required or the exhibit's rest scene would be that panel forever.
#
# Media: the A310 machine romset (four 0296,0*-02.rom halves, bios=311) plus
# the shared Archimedes keyboard MCU romset — MEASURED good against a system
# MAME 0.264 -verifyroms run, smoke-booted 2026-09-20 to the RISC OS 3.11
# Desktop (icon bar + pointer visible, non-red raster) after pressing a key
# past the preliminary-driver warning. Source: archive.org
# mame-0.264-roms-non-merged (aa310.zip sha256 04d17d96963816721219691857af17
# e6439ae30088ebf2e89fac9d8b12d7194b; archimedes_keyboard.zip sha256
# 1d02b14cd4d2ff80a343c3afb1ba43de0bd77815952816fc19d0736f8644664e) — staged
# under /data/assets-staging/riscos3/, MANIFEST.sha256 there.
#
# POINTER. The Archimedes mouse is NOT the SGI Indy's hle_ps2_mouse the base
# ctlsock module hardcodes, so ptr-tags is mandatory: the ports are
# :keyboard:MOUSE.0/.1 (IPT_MOUSE_X/Y, mask 0xffff) and :keyboard:MOUSE.2,
# whose three buttons are PORT_NAMEd "Mouse Left"/"Mouse Center"/"Mouse Right"
# and are IP_ACTIVE_LOW (archimedes_keyb.cpp:206-215) — hence btn-active-low
# as well. RISC OS is a three-button desktop (Select/Menu/Adjust) and all
# three are bound.
#
# THE MAGNITUDE WAS DISCARDED ON THE WIRE, and that is what
# mame-archimedes-kbd-mouse-carry.patch fixes. Upstream's update_mouse runs at
# 4 kHz and, on ANY non-zero delta, advances the quadrature phase by exactly
# ONE step and then assigns `m_mouse_x = x` — so a 600-count move written in
# one go moved the guest pointer ZERO pixels (measured 2026-09-20). Pacing one
# count per emulated millisecond does deliver the motion, but it caps a MOVEA
# round at MAME_CTL_MOVE_STEP=1 and the closed loop gives up before it crosses
# the screen (ten targets, ten giveups, worst error 332 px). The carry patch
# advances the recorded position by one unit per tick and keeps the remainder,
# so the fleet-default step works and nothing is lost.
#
# THE SENSOR is the VIDC's own hardware cursor register. acorn_vidc.cpp draws
# the sprite at m_crtc_regs[CRTC_HCSR]-[CRTC_HBSR] / [CRTC_VCSR]-[CRTC_VBSR]
# and save_pointer()s m_crtc_regs as a u32[16], so the cursor position is
# elements 6 and 14 — byte offsets 24 and 56. ram-cursor supplies the
# `item@offset:width` window and the CAL_SX/SY scale; item-window-sized
# relaxes that window from a byte array to an array of any element size,
# which is the only reason this register is readable at all.

NATIVE_DRIVER=aa310
NATIVE_SUBTARGET=aa310
NATIVE_SOURCES=src/mame/acorn/aa310.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=(-bios 311)
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch mame-ctlsock-ptr-tags.patch
  mame-ctlsock-btn-active-low.patch mame-ctlsock-ram-cursor.patch
  mame-ctlsock-item-window-sized.patch mame-archimedes-kbd-mouse-carry.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" aa310 /data/assets-staging/riscos3 "$roms" \
    aa310 archimedes_keyboard
}

# Power-on with the aa310/311 romset reaches the RISC OS 3.11 Desktop: a
# mid-grey raster (mostly non-black) with the icon bar band along the
# bottom. MEASURED 2026-09-20 with system MAME 0.264 (same driver/romset
# metadata as the pinned 0.289): boot completes within ~15s to the Desktop.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 3000 20
}
