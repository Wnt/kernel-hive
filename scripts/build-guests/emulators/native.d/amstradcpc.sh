# shellcheck shell=bash
# native.d/amstradcpc.sh — host-native conversion stanza for the Amstrad CPC
# 6128, which replaces the station's Caprice32-in-a-Debian-kiosk bridge
# (2026-10-04). Keys reached cap32 through QMP -> guest kernel -> X -> SDL, so
# whenever labhost descheduled the kiosk's vCPU the in-guest emulator missed
# key edges (docs/guests/amstradcpc.md). Here the CPC's own keyboard matrix is
# driven by ctlsock in emulated time, so host load cannot drop a key.
#
# Driver cpc6128 (amstrad/amstrad.cpp, status good). makedep pulls in
# amstrad_m.cpp through amstrad.h, so the one source file is enough. The
# romset is two members, both the Amstrad ROMs Caprice32 bundles under
# Amstrad's emulator permission, fetched by a pinned commit and staged with a
# MANIFEST.sha256 at /data/assets-staging/amstradcpc/ on labhost (never
# committed): cpc6128.rom (OS + Locomotive BASIC 1.1) and amsdos.rom, which
# is MAME's cpcados.rom byte for byte. stage-romset.py matches them by SHA1
# against THIS binary's -listxml, so the file names do not matter.

NATIVE_DRIVER=cpc6128
NATIVE_SUBTARGET=cpc6128
NATIVE_SOURCES=src/mame/amstrad/amstrad.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=()

native_stage_roms() {
  local roms="$1"
  local stage=/data/assets-staging/amstradcpc
  (cd "$stage" && sha256sum -c --quiet MANIFEST.sha256) ||
    die "the staged CPC ROMs do not match $stage/MANIFEST.sha256"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" cpc6128 "$stage" "$roms" cpc6128
}

# Power-on is the CTM640 colour monitor's blue paper under the whole 40-column
# text area, with the yellow "Amstrad 128K Microcomputer (v3)" banner and
# `Ready` -- most of the surface is lit, where a red warnings panel or a black
# stall would not be.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 300000 6
}
