# shellcheck shell=bash
# Philips MSX2 with a 512 KiB mapper and MSX mouse for SymbOS 4.0.
NATIVE_DRIVER=nms8250
NATIVE_SUBTARGET=msx2
NATIVE_SOURCES=src/mame/msx/msx2.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=(-cartslot1 mm512k -gen1 mouse -view "Screen 0 Standard (4:3)")
NATIVE_EXTRA_PATCHES=(mame-ctlsock-ptr-tags.patch
  mame-ctlsock-move-step-cap.patch mame-ctlsock-open-loop-gain.patch
  mame-ctlsock-home-drain.patch mame-ctlsock-count-carry.patch
  mame-ctlsock-screen-origin.patch mame-ctlsock-msx-cursor.patch)
NATIVE_SKIP_WARNINGS=0

native_stage_roms() {
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" nms8250 /data/assets-staging/msx2/roms "$1" nms8250
}

native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 340000 6
}
