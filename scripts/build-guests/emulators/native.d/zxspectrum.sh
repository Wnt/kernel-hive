# shellcheck shell=bash
# native.d/zxspectrum.sh — host-native conversion stanza for the ZX Spectrum
# 48K. The bridge ran Debian's apt MAME 0.251, a pin that does not exist in
# trixie — the host build dissolves it. The romset is re-derived from THIS
# binary's own listxml out of the same Debian spectrum-roms package the
# kiosk used (staged as the .deb; extracted to scratch and sha1-matched).

NATIVE_DRIVER=spectrum
NATIVE_SUBTARGET=spectrum
NATIVE_SOURCES=src/mame/sinclair/spectrum.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=(-bios en)

native_stage_roms() {
  local roms="$1"
  local scratch="$WORK/zxspectrum-staging"
  rm -rf "$scratch"
  mkdir -p "$scratch"
  dpkg-deb -x /data/assets-staging/zxspectrum/spectrum-roms_20081224-5_all.deb "$scratch/deb"
  find "$scratch/deb" -type f -exec cp {} "$scratch/" \;
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" spectrum "$scratch" "$roms" spectrum
}

# Power-on is the machine's own WHITE paper across the whole raster with the
# 1982 copyright line — over half the surface is lit, and a warnings panel
# (if 0.289 ever grew one for this driver) would read far darker: the floor
# doubles as the no-panel assertion.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 400000 12
}
