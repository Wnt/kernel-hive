# shellcheck shell=bash
# native.d/palmos.sh — host-native conversion stanza for Palm OS 3.3 on a
# Palm III (MAME driver `palmiii`, mame/palm/palm.cpp). The wave seed
# proposed MAME palmiii first, m505 second; palmm505 in this MAME version
# (0.289) is MACHINE_NOT_WORKING, so palmiii — the one driver in the family
# that ships MACHINE_SUPPORTS_SAVE — is the whole first station, not a
# fallback.
#
# ROM: only the French and German Palm OS 3.3 dumps hosted at palmdb.net's
# palm-roms-complete collection are byte-exact matches for a BIOS option this
# driver defines (palmos33-fr-iii.rom / palmos33-de-iii.rom, both inside the
# PALM_68328_BIOS macro at mame/palm/palm.cpp:804). palmdb's own
# "Palm-III-3.3-en.rom" is 1343488 bytes, not the 2097152-byte English 3.0/3.3
# dump this driver wants, and no byte-matching English dump was found in the
# time this wave budgeted — see docs/lab/PALMOS-WAVE.md. French wins the
# first release; the locale is a documented fact, not a guess.
#
# POINTER: Palm's pen is IPT_LIGHTGUN_X/Y, a true ABSOLUTE analog ioport
# field (PORT_MINMAX(0,0xa0)), not a relative counter like every other MAME
# station's mouse. mame-ctlsock-abs-fields.patch (new this wave) adds
# MAME_CTL_ABS=1: MOVEA then writes m_x_field/m_y_field directly, scaled from
# the published surface into the field's own range — no accumulator, no
# cursor readback, because there is no on-screen cursor to converge against.
# ptr-tags binds the fields themselves (PENX:Pen X / PENY:Pen Y / PENB:Pen
# Button — tags found by grepping mame/palm/palm.cpp's INPUT_PORTS_START).

NATIVE_DRIVER=palmiii
NATIVE_SUBTARGET=palmos
NATIVE_SOURCES=src/mame/palm/palm.cpp
# Published surface = the driver's own visarea (160x220); this IS the pen's
# coordinate space too, so no letterbox math is needed anywhere downstream.
NATIVE_GEOM=160x220
NATIVE_MAME_ARGS=(-bios 3.3f)
NATIVE_EXTRA_PATCHES=(mame-ctlsock-ptr-tags.patch mame-ctlsock-abs-fields.patch)
NATIVE_SKIP_WARNINGS=0

native_stage_roms() {
  local roms="$1"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" palmiii /data/assets-staging/palmos/roms "$roms" \
    palmiii
}

# Power-on with a fresh (unformatted) NVRAM is Palm OS's own "Welcome"/setup
# flow rather than the Applications Launcher; the smoke gate here only proves
# the machine draws SOMETHING on the published surface (the LCD is not black
# once the 68328 core starts fetching), same discipline as every other
# stanza. The launcher-scene proof is a separate framebuffer capture in the
# golden stream's own sandbox rig.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 400 8
}
