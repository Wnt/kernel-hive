# shellcheck shell=bash
# native.d/domainos.sh — host-native stanza for the Apollo DN3500 running
# Domain/OS SR10.4.1 (the domainos wave, docs/lab/DOMAINOS-WAVE.md). Driver
# dn3500 lives in apollo/apollo.cpp (DN_FLAGS = 0: no nag panel, and the
# driver registers its state, so the shared launcher's SAVEST/LOADST
# checkpoint applies — the golden stream owns the verdict).
#
# The DN3500's default layout (apollo_15i.lay, view "Apollo (1024x800)")
# paints the 1024x800 raster PLUS a 44 px strip of function-key legends and
# LEDs under it — a MAME artefact, not the machine. The layout's own
# "XGA Screen (1024x768)" view is the bare raster, so the station publishes
# that view at the fleet's 1024x768 surface (MEASURED 2026-09-09: the
# default view snapshots at 1024x844; `-view xga` is NOT accepted as a
# short name — the full view name is required).

NATIVE_DRIVER=dn3500
NATIVE_SUBTARGET=domainos
NATIVE_SOURCES=src/mame/apollo/apollo.cpp
NATIVE_GEOM=1024x768
# Device set per docs/lab/DOMAINOS-WAVE.md, confirmed on stock 0.276
# -listslots/-listmedia (2026-09-09): isa1 = OMTI 8621 ESDI/floppy
# controller (winchester1 = -disk1 <awd>), isa2 = Archive SC-499 cartridge
# tape (unused, but the boot ROM's self test enumerates it), isa3 = 3Com
# 3C505 EtherLink Plus (Domain/OS TCP/IP; the retronet tap is OPEN). All
# three are the driver's defaults — set explicitly so a MAME default change
# can never silently drop one, exactly as samcoupe does for its drives.
NATIVE_MAME_ARGS=(-isa1 wdc -isa2 ctape -isa3 3c505 -view "XGA Screen (1024x768)")
# Pointer: the Apollo mouse hangs off the keyboard (apollo_kbd.cpp):
# :kbd:mouse1 buttons ("Left/Right/Center mouse button"), :kbd:mouse2/3 =
# IPT_MOUSE_X/Y as 8-bit fields the keyboard device DIFFERENCES per sample
# (read_mouse: dx = x - last_x). That is the Apple II Mouse Card's shape
# exactly, so this stanza carries apple2e's whole open-loop stack: ptr-tags
# (rebind the engine to these tags/names, PTR_MOD 256), move-step-cap (a
# write over 127 counts reads BACKWARDS through an 8-bit difference),
# open-loop-gain (no readable cursor register — the DM draws its cursor in
# software), home-drain and count-carry. The station fixture sets the
# tags/names/modulus and the measured gain.
# The 3C505 card's `3c505-nw.bin` has NO GOOD DUMP KNOWN, so every start
# raises MAME's startup warning panel — and that panel PAUSES the machine
# until a key is pressed, which a headless kiosk never sends (MEASURED
# 2026-09-09: the throttled rig sat at 3 % CPU with the ctlsock never
# acking; a `-str` run skips the panel, which is why the build gate and a
# race harness both "passed"). ui.ini's skip_warnings is only honoured with
# the skip-warnings patch (atari800xl's finding), so it is stacked here too.
NATIVE_EXTRA_PATCHES=(mame-ctlsock-ptr-tags.patch mame-ctlsock-move-step-cap.patch mame-ctlsock-open-loop-gain.patch mame-ctlsock-home-drain.patch mame-ctlsock-count-carry.patch mame-ctlsock-field-token.patch mame-irix-skip-warnings.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  # dn3500 wants its boot PROM (3500_boot_12191_7.bin) plus the 3C505 card's
  # firmware and station-address PROMs (0729-12_a.3h, 0729-62_a.3f,
  # 3000_3c505_010728-00.bin, 3com.9h, apollo.9h — the `3c505` device set
  # -listroms folds into dn3500's list; 3c505-nw.bin has no good dump and
  # is expected missing). Staged flat under the wave's sandbox media dir
  # (/data/assets-staging is root-owned inside CT950 — playbook §0 wall
  # table); origin bitsavers.org/bits/Apollo/firmware, hashes in the wave doc.
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" dn3500 "${DOMAINOS_ROM_STAGING:-/data/vms/sandbox/domainos/media/roms-flat}" "$roms" \
    dn3500 3c505
}

# Power-on with no disk is the boot PROM's self-test transcript — white text
# on black ("SELF TESTS IN PROGRESS", one line per test, "WINCHESTER DISK ...
# NOT FOUND") — sparse text, so a low floor. MEASURED on stock 0.276
# (2026-09-09): the transcript is on screen within 8 emulated seconds; the
# self tests + kernel banner reached ~40 lines by 120 s. Floor 1000 over 12 s.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 1000 12
}
