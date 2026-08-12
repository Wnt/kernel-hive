# shellcheck shell=bash
# native.d/kc854.sh — host-native conversion stanza for the KC 85/4 (machine
# kc85_4, -bios caos42; ddr/kc.cpp). Same de-bridging-is-the-fix story as
# mpf2 (bookworm rollback dissolves with the kiosk). The driver nags, so
# skip-warnings is required. The operator staged the WHOLE set as
# kc85_2.zip; it is unzipped to a scratch dir so the members can be
# sha1-matched against this binary's own listxml like every other station.

NATIVE_DRIVER=kc85_4
NATIVE_SUBTARGET=kc85
NATIVE_SOURCES=src/mame/ddr/kc.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=(-bios caos42)
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  local scratch="$WORK/kc854-staging"
  rm -rf "$scratch"
  mkdir -p "$scratch"
  unzip -o -q -j /data/assets-staging/kc854/kc85_2.zip -d "$scratch"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" kc85_4 "$scratch" "$roms" kc85_4
}

# Power-on is the CAOS 4.2 menu — bright text; non-black floor.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 3000 15
}
