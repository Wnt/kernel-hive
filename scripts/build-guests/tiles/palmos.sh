#!/bin/bash
# scripts/build-guests/tiles/palmos.sh — verify the staged Palm III ROM.
#
# Unlike most tiles/*.sh builders this station has NO media to compose: the
# whole "disk" is the ROM MAME's palmiii driver boots from directly (Palm OS
# lives in the firmware image, not on a separate floppy/hard-disk asset like
# atari800xl's hive.atr or apple2gs's hive.hdv). This script's only job is to
# confirm the staged blob is still the byte-exact match this wave verified
# against mame/palm/palm.cpp's BIOS table (docs/lab/PALMOS-WAVE.md) before
# scripts/build-guests/emulators/build-mame-native.sh palmos stages it into
# the rompath via native.d/palmos.sh's native_stage_roms().
#
# The MAME BINARY itself (the actual "build" for a host-native station) is
# scripts/build-guests/emulators/build-mame-native.sh palmos — this script
# does not invoke it; run that directly (docs/lab/PALMOS-WAVE.md has the
# exact command and work-dir this wave used).
set -euo pipefail

ROM_DIR="${PALMOS_ROM_DIR:-/data/assets-staging/palmos/roms}"
ROM_FILE="$ROM_DIR/palmos33-fr-iii.rom"
EXPECT_SHA1="c7c90df814d4f97958194e0bc28c595e967a4529"
EXPECT_SIZE=2097152

log() { printf '[build:palmos] %s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

[ -f "$ROM_FILE" ] || die "missing $ROM_FILE — stage Palm-III-3.3-fr.rom from https://palmdb.net/app/palm-roms-complete first (docs/lab/PALMOS-WAVE.md)"

SIZE="$(stat -c %s "$ROM_FILE")"
[ "$SIZE" = "$EXPECT_SIZE" ] || die "size mismatch: $ROM_FILE is $SIZE bytes, expected $EXPECT_SIZE"

SHA1="$(sha1sum "$ROM_FILE" | cut -d' ' -f1)"
[ "$SHA1" = "$EXPECT_SHA1" ] || die "sha1 mismatch: $ROM_FILE is $SHA1, expected $EXPECT_SHA1 (mame/palm/palm.cpp's palmos33-fr-iii.rom BIOS option)"

log "OK: $ROM_FILE matches the palmiii driver's palmos33-fr-iii.rom BIOS option ($SIZE bytes, sha1 $SHA1)"
