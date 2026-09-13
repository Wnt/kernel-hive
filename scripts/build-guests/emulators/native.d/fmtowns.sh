# shellcheck shell=bash
# native.d/fmtowns.sh — host-native conversion stanza for the FM Towns
# running Towns System Software V2.1 L51 (the fmtowns wave, docs/lab/
# FMTOWNS-WAVE.md). Driver lives in fujitsu/fmtowns.cpp on the fleet pin
# mame0289 and is MACHINE_NOT_WORKING for every machine in the driver
# (fmtowns/fmtownsftv/fmtownshr/fmtownssj/fmtownsux): the startup warning
# panel PAUSES a headless kiosk until a key is pressed, exactly the
# domainos/atari800xl shape, so this stanza carries the same skip-warnings
# patch + ui.ini knob rather than anything fmtowns-specific.
#
# Machine choice: fmtownsftv (the 1994 FreshTV revision). The media agent's
# first pass staged only the 5 CANONICAL fmt_*.rom names (which turn out to
# be a MIX of base-fmtowns's fmt_sys.rom/fmt_dos.rom and the Towns II
# fmt_f20/fmt_dic/fmt_fnt — no single machine's set matched all 5 by sha1).
# The fix: /data/assets-staging/fmtowns/roms/fmtowns.7z is the WHOLE MAME
# 0.272 merged romset (every variant: fmt_*_a, fmt_*_0, fmthr_sys, all five
# mytowns*.rom serial ROMs) — extract it flat and point native_stage_roms at
# THAT, and fmtownsftv's set (including the 32-byte mytownsftv.rom) matches
# completely by sha1. A shipped station's tiles/fmtowns.sh builder should
# extract this 7z the same way rather than relying on a partial pre-stage.
NATIVE_DRIVER=fmtownsftv
NATIVE_SUBTARGET=fmtowns
NATIVE_SOURCES=src/mame/fujitsu/fmtowns.cpp
NATIVE_GEOM=1024x768
# Slots per the driver's defaults (fujitsu/fmtowns.cpp, confirmed against
# this build's -listslots fmtownsftv): pad1/pad2 are the MSX-style
# general-purpose ports, defaulting to townspad/mouse — set explicitly so a
# MAME default change can never silently drop one, as every other station's
# stanza does for its own device set. The CD-ROM is NOT here: it is handed
# to the binary at launch time (the shared launcher's -cdrom / MAME_NATIVE_ARGS
# fixture value carries it per-station, same as MAME_NATIVE_DISK_TEMPLATE for
# other stations), so the build-time boot gate below proves only the
# no-disc system screen, not the booted desktop.
NATIVE_MAME_ARGS=(-pad1 townspad -pad2 mouse)
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  # FMTOWNS_ROM_STAGING must point at a FLAT directory holding every member
  # of the MAME 0.272 fmtowns.7z romset (extracted, not the .7z itself) —
  # stage-romset.py matches by sha1 regardless of filename case/suffix.
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" fmtownsftv "${FMTOWNS_ROM_STAGING:-/data/vms/sandbox/fmtowns/race/mame/roms-flat}" "$roms" \
    fmtownsftv
}

# Power-on with no CD-ROM attached is the FM Towns system/boot-selector
# screen (a text banner over the machine's native palette, not black) —
# floor measured on this build's gate run, ~half the measured lit-pixel
# count per the brief's convention (see the race report for the exact
# number substituted here once measured).
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 1 8
}
