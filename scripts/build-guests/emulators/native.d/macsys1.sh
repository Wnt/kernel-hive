# shellcheck shell=bash
# native.d/macsys1.sh — host-native conversion stanza for the Macintosh 128K
# running Macintosh System 1.0 / Finder 1.0 (January 1984), the macsys1 wave.
# Driver lives in src/mame/apple/mac128.cpp on the fleet pin mame0289.
#
# MEASURED from the driver source (mac128.cpp @ mame0289, 2026-09-13):
#   COMP( 1984, mac128k, 0, 0, mac128k, macplus, ... MACHINE_SUPPORTS_SAVE )
# — status is good AND save-state capable, so this station needs NEITHER the
# mame-irix-skip-warnings.patch (no MACHINE_NOT_WORKING nag panel to pause a
# headless kiosk) NOR MAME_NATIVE_CHECKPOINT=0: the shared launcher's
# checkpoint restore applies unmodified, exactly like apple2e.
NATIVE_DRIVER=mac128k
NATIVE_SUBTARGET=mac128
NATIVE_SOURCES=src/mame/apple/mac128.cpp
# The Mac 128K's video is 512x342 1-bit. The station publishes the fleet
# surface 1024x768 and lets MAME's own aspect handling letterbox the exact
# 2x integer scale (1024x684) inside it, as every other native station does.
NATIVE_GEOM=1024x768
# mac128k's machine_config (mac128.cpp) fixes its own device set: two
# applefdintf 3.5" single-density (400K) drives on the IWM ("fdc:0"/"fdc:1",
# i.e. -flop1/-flop2), 128K RAM, RTC3430040. There are no slots to pin, so
# this array is empty — the boot media is handed to the binary at launch time
# through the fixture's MAME_NATIVE_ARGS, like fmtowns's -cdrom.
NATIVE_MAME_ARGS=()
# Pointer: a Macintosh 128K has no ADB (that arrives with the Mac II/SE). Its
# mouse is the quadrature mouse read through the VIA, exposed by the driver's
# `macplus` input port map as three TOP-LEVEL ioports (mac128.cpp:1403-1411):
#   PORT_START("MOUSE0")  PORT_BIT(0x01, IP_ACTIVE_HIGH, IPT_BUTTON1) PORT_NAME("Mouse Button")
#   PORT_START("MOUSE1")  PORT_BIT(0xff, 0x00, IPT_MOUSE_X)
#   PORT_START("MOUSE2")  PORT_BIT(0xff, 0x00, IPT_MOUSE_Y)
# — NOT the SGI Indy's hle_ps2_mouse tags the fleet ctlsock module hardcodes,
# so mame-ctlsock-ptr-tags.patch is mandatory to rebind
# MAME_CTL_PTR_TAGS=":MOUSE0,:MOUSE1,:MOUSE2" with
# MAME_CTL_BTN_NAMES="Mouse Button,,". The patch's type-based IPT_MOUSE_X/Y
# match (the fmtowns fix) is what makes MOUSE1/MOUSE2 bind at all: their
# PORT_NAMEs are MAME's generated defaults, not the module's hardcoded
# "Mouse X"/"Mouse Y".
#
# Like apple2e (and unlike the Indy), this machine has no host-readable cursor
# register, so MOVEA runs OPEN-LOOP: the same gain/step-cap/home-drain/
# count-carry corrections the Apple II Mouse Card needed apply here for the
# same reason — an 8-bit delta field that the guest's VIA nets and drains.
# ...but the open loop is NOT what ships. A 68000 Mac's ROM accelerates the
# mouse at VBL (MEASURED on the rig: 1.83 px/count when the counts trickle,
# ~1.98 in a burst), so no single gain is 1:1, and the 512x342 raster is
# LETTERBOXED 2x inside the 1024x768 surface (1024x684 at y=42) so the open
# loop's homing corner is not the guest's origin. mame-ctlsock-abs-ram.patch
# replaces both problems with an absolute WRITE into the Mac's own documented
# low-memory pointer globals (MTemp $828 / RawMouse $82C / Mouse $830, plus
# CrsrNew $8CE := CrsrCouple $8CF) through the published-rect transform. Zero
# counts are issued. The open-loop stack stays in the build as the fallback
# the module uses if the address space cannot be resolved.
NATIVE_EXTRA_PATCHES=(mame-ctlsock-ptr-tags.patch mame-ctlsock-move-step-cap.patch mame-ctlsock-open-loop-gain.patch mame-ctlsock-home-drain.patch mame-ctlsock-count-carry.patch mame-ctlsock-abs-ram.patch)
NATIVE_SKIP_WARNINGS=0

native_stage_roms() {
  local roms="$1"
  # TWO romsets, not one. Since MAME 0.221 the Macintosh keyboard is its own
  # emulated device (an Intel 8021 MCU, bus/mackbd) with its own ROM set
  # `mackbd_m0110` (ip8021h_2173.bin, 1 KB) that -listxml mac128k does NOT
  # fold into mac128k's own <rom> list — exactly the apple2e d2fdc/m68705p3
  # shape. Omit it and the machine boots with a DEAD keyboard.
  # MEASURED 2026-09-13 (media agent, stock labhost mame 0.276):
  # `romset mac128k is good` only with both sets present.
  #
  # The media agent stages the two sets as TorrentZipped .zip archives, so
  # extract them FLAT into our own work dir every build (~132 KB unpacked) and
  # hand stage-romset.py that — it matches staged blobs to listxml members by
  # sha1, and a zip is not a blob. mac128k.zip also carries the mac512k
  # sub-directory members; flat extraction with -j drops the directory and
  # sha1 matching keeps the right four bytes-for-bytes.
  local flat="$WORK/roms-flat"
  if [ ! -f "$flat/ip8021h_2173.bin" ]; then
    mkdir -p "$flat"
    for z in mac128k mackbd_m0110; do
      unzip -j -o -q "${MACSYS1_ROM_STAGING:-/data/assets-staging/macsys1}/$z.zip" -d "$flat"
    done
  fi
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" mac128k "$flat" "$roms" \
    mac128k mackbd_m0110
}

# Power-on with NO floppy attached is the Mac's own "insert disk" screen: the
# 1-bit Happy-Mac/floppy-with-question-mark icon blinking in the middle of an
# otherwise WHITE 512x342 raster. A 1-bit Mac screen is white-on-black
# inverted from every other station's gate assumption — the desktop pattern is
# overwhelmingly LIT, so the non-black floor here is high, not low.
# Floor measured on this build's own gate run and recorded in
# docs/lab/MACSYS1-WAVE.md.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" "${MACSYS1_GATE_FLOOR:-50000}" 8
}
