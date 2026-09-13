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
# mame-ctlsock-ptr-tags.patch: fmtowns's mouse is an MSX general-purpose-port
# device (bus/msx/ctrl/mouse.cpp), tagged :pad2:mouse:BUTTONS/MOUSE_X/MOUSE_Y
# -- NOT the SGI Indy's hle_ps2_mouse the fleet ctlsock module hardcodes, so
# without this patch the module's own setup line prints "btns=0 axes=0" and
# every MOVE/MOVEA/CLICK is acked into a null field (docs/lab/FMTOWNS-WAVE.md
# SS Pointer, measured on the live station 2026-09-13). Also carries the
# type-based Mouse-X/Y binding fix (KEYDUMP measured the field names as
# "Mouse X 2"/"Mouse Y 2" on pad2, not the module's hardcoded "Mouse X"/
# "Mouse Y", so axes stayed 0 until this landed too).
#
# mame-ctlsock-btn-active-low.patch is DELIBERATELY NOT HERE, and
# MAME_CTL_BTN_ACTIVE_LOW must stay unset for this station. It was written on
# the theory that the MSX mouse's IP_ACTIVE_LOW BUTTONS port needed the module
# to invert set_value() -- it does not. MAME already applies the polarity
# itself: ioport_port::read() ends with `result ^= m_live->defvalue`, and for
# an IP_ACTIVE_LOW field the defvalue bit IS the mask, so set_value(1) already
# produces the electrically-pressed (logic 0) level. Setting the env inverts a
# polarity MAME handles and turns every click into a guaranteed no-op.
# MEASURED 2026-09-13 with kh-fmtowns-padport-debug.patch: with the env unset,
# DOWN1 takes the byte the GUEST reads from raw=f0 to raw=e0 (bit 4 low =
# button 1 pressed), through the driver's own pad mask (mask=2f/0f, so bits
# 4 and 5 are ungated). See docs/lab/FMTOWNS-WAVE.md SS Pointer.
#
# The rig's exact pointer env (measured 2026-09-13):
# MAME_CTL_PTR_TAGS=":pad2:mouse:BUTTONS,:pad2:mouse:MOUSE_X,:pad2:mouse:MOUSE_Y"
# MAME_CTL_BTN_NAMES="P2 Button 1,P2 Button 2,"
# The apple2e open-loop absolute chain (move-step-cap -> open-loop-gain ->
# home-drain -> count-carry) turns MOVEA from a 1.0-gain dead reckoner into a
# seeded open loop. fmtowns needs every link: the MSX mouse packs each poll's
# delta into a SIGNED BYTE (bus/msx/ctrl/mouse.cpp), which is exactly the
# narrow differencing window move-step-cap exists for (MAME_CTL_PTR_MOD=256
# caps the pacer at 128 counts); the guest px/count is ~5.3, not 1.0, which is
# open-loop-gain's MAME_CTL_GAIN_X/Y; the first-target home slam parks counts
# in the device accumulator, which is home-drain; and a fixed-size pacer chunk
# rounds the same residue every window, which is count-carry.
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch mame-ctlsock-ptr-tags.patch \
  mame-ctlsock-move-step-cap.patch mame-ctlsock-open-loop-gain.patch \
  mame-ctlsock-home-drain.patch mame-ctlsock-count-carry.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  # The media-staged pre-extracted fmt_*.rom names (5 canonical filenames)
  # are a MIX of base-fmtowns and Towns II member hashes — no single machine
  # matches all 5 by sha1. /data/assets-staging/fmtowns/roms/fmtowns.7z is
  # the WHOLE MAME 0.272 merged romset (every variant + all five
  # mytowns*.rom serial ROMs); extracting THAT flat gives fmtownsftv a
  # complete sha1 match (race-proven 2026-09-13, including the 32-byte
  # mytownsftv.rom). Extract into our own work dir every build — cheap
  # (~4.6 MB unpacked) and keeps this stanza independent of any race
  # sandbox's leftover directory.
  local flat="$WORK/roms-flat"
  if [ ! -f "$flat/mytownsftv.rom" ]; then
    mkdir -p "$flat"
    7z x -y -o"$flat" "${FMTOWNS_ROMSET_7Z:-/data/assets-staging/fmtowns/roms/fmtowns.7z}" >/dev/null
  fi
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" fmtownsftv "${FMTOWNS_ROM_STAGING:-$flat}" "$roms" \
    fmtownsftv
}

# Power-on with no CD-ROM attached is the FM Towns boot-selector screen
# (the paperclip/dog/pencil "FM TOWNS" logo banner over black, plus a
# Japanese "disk error" line bottom-left once the boot device probe fails
# with no media attached) — MEASURED on this build's gate run (2026-09-13,
# fmtownsftv, full romset staged, -str 8): 50291 lit pixels of 786432
# total. Floor set to 25000, ~half the measured count per the brief's
# convention (samcoupe's stanza comment).
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 25000 8
}
