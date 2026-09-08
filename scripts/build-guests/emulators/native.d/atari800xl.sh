# shellcheck shell=bash
# native.d/atari800xl.sh — host-native conversion stanza for the Atari 800XL
# PAL, the atari800xl wave's `native` stream. Driver a800xlp lives in
# atari/atari400.cpp; docs/lab/ATARI800XL-WAVE.md is the ledger. This driver
# is MACHINE_IMPERFECT_GRAPHICS (a nag panel unless skipped) and does NOT
# carry MACHINE_SUPPORTS_SAVE (the golden stream owns the SAVEST/LOADST
# verdict and MAME_NATIVE_CHECKPOINT decision; native only reports what it
# measured on its own rig).

NATIVE_DRIVER=a800xlp
NATIVE_SUBTARGET=atari800xl
NATIVE_SOURCES=src/mame/atari/atari400.cpp
NATIVE_GEOM=1024x768
# Device set per docs/lab/ATARI800XL-WAVE.md (spine, confirmed against stock
# 0.276's -listslots/-listmedia on labhost; native stream reconfirms on
# 0.289): Atari 1050 disk drive on the SIO chain (a800xlp's own DEFAULT sio
# slot — MEASURED 2026-09-08: passing "-sio a1050" explicitly on the
# command line, even though it names the default value, makes THIS build
# silently drop the floppydisk1..4 (-flop1..4) media options — "-flop1"
# then errors as an unknown option. Omitting -sio entirely keeps the same
# a1050 drive attached AND keeps -flop1..4 working; do not add -sio back),
# CX40 joystick on controller port 1 (driven from the keyboard's arrow
# keys + a fire key through keymap override rows). Cart slot stays EMPTY
# so the built-in Atari BASIC cartridge (co60302a.rom) is present at boot.
NATIVE_MAME_ARGS=(-ctrl1 joy)
# No pointer device on this machine (stream.pointer.transport: none) — no
# pointer patches needed, keyboard+joystick only.
# MEASURED on the rig (2026-09-08): ui.ini's skip_warnings alone does
# NOTHING — stock MAME shows the "known problems: Completely unemulated
# features: disk / Imperfectly emulated features: graphics" panel
# regardless (options().skip_warnings() is never consulted upstream). The
# mpf2-style patch is REQUIRED to make the option take effect; the panel
# would otherwise BE the exhibit, exactly as documented in mpf2.sh.
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  # a1050 (the Atari 1050 disk drive) carries its own controller firmware
  # ROM as a sub-device MAME's -listxml does not fold into a800xlp's own
  # <rom> list. Fetched the same way as apple2e's sub-device ROMs if not
  # already staged: found by running the gate and reading its "NOT FOUND"
  # lines, never guessed.
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" a800xlp /data/assets-staging/atari800xl/roms "$roms" \
    a800xlp atari1050
}

# Power-on with -sio a1050 attached and no disk in -flop1 (this stanza's
# NATIVE_MAME_ARGS — the device set the media stream will populate) is a
# blue "BOOT ERROR" retry screen, not the BASIC READY prompt: the XL OS
# retries the boot sector forever when a disk drive is powered with no
# disk (real hardware behaviour, docs/lab/ATARI800XL-WAVE.md). It is
# still full-screen blue text, MEASURED 604043 lit pixels over 6 emulated
# seconds (2026-09-08) — floor set to half that. The bare BASIC READY
# prompt (confirmed reachable with -sio omitted) is proven separately on
# the native stream's own sandbox rig, not this build-time gate; once the
# media stream's hive.atr exists this device set boots it instead of
# looping.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 300000 6
}
