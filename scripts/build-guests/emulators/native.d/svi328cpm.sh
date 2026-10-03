# shellcheck shell=bash
NATIVE_DRIVER=svi328
NATIVE_SUBTARGET=svi328
NATIVE_SOURCES=src/mame/svi/svi318.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=(-bios v111 -exp sv601 -exp:sv601:6 sv801 -exp:sv601:0 sv806 -numscreens 1 -view0 "Screen 0")
NATIVE_EXTRA_PATCHES=(mame-sv801-ready.patch)
NATIVE_SKIP_WARNINGS=0

native_stage_roms() {
  local source="${SVI_ROM_SOURCE:-/data/assets-staging/svi328cpm/roms}"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" svi328 "$source" "$1" svi328
  mkdir -p "$1/sv806"
  echo "ed45cb0e9bd18a9d7bd74f87e620f016a7ae840f  $source/sv806.ic27" | sha1sum --check --status
  install -m 644 "$source/sv806.ic27" "$1/sv806/sv806.ic27"
}

native_boot_gate() {
  local media="${SVI_MEDIA_SOURCE:-/data/vms/streamhost/assets/svi328cpm/media/hive-cpm.imd}"
  cp "$media" "$3.disk.imd"
  chmod u+w "$3.disk.imd"
  NATIVE_MAME_ARGS+=(-flop1 "$3.disk.imd")
  native_gate_nonblack "$1" "$2" "$3" 5000 15
  NATIVE_MAME_ARGS+=(-autoboot_script "$HERE/native.d/svi328cpm-idle.lua" -autoboot_delay 1)
  native_gate_nonblack "$1" "$2" "$3.idle" 5000 120
  grep -q 'SV801-IDLE-MBASIC-PASS:' "$3.idle/mame.log" ||
    die "SV-801 motor-off read regression; see $3.idle/mame.log"
  NATIVE_MAME_ARGS=("${NATIVE_MAME_ARGS[@]:0:${#NATIVE_MAME_ARGS[@]}-4}")
}
