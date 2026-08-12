# shellcheck shell=bash
# native.d/armeval.sh — host-native conversion stanza for the Acorn ARM
# Evaluation System: the SAME bbcb build as bbcmicro (one driver family, one
# binary shape), plus the machine's own slots and media:
#   -tube arm        the ARM second processor IS the exhibit
#   -fdc acorn1770   the ADFS .adl discs are double density; the 8271 cannot
#   -rom3 ADFS 1.30  socket 1 kills the Tube outright (armeval.sh's bake-off)
#   -flop1 disc3     ARM BBC Basic lives on the floppy as $.AB
# The golden scene additionally has "*LIB $" and "AB" typed at the A*
# supervisor prompt BEFORE the savestate — baked at cutover through the
# ctlsock natural-keyboard verbs, exactly as documented in the fixture.

NATIVE_DRIVER=bbcb
NATIVE_SUBTARGET=bbcb
NATIVE_SOURCES=src/mame/acorn
# The armeval kiosk published an 800x600 X root; the converted station keeps
# its geometry.
NATIVE_GEOM=800x600
ARMEVAL_MEDIA=/data/vms/streamhost/assets/armeval/mame-native/media
NATIVE_MAME_ARGS=(
  -tube arm -fdc acorn1770
  -rom3 "$ARMEVAL_MEDIA/Acorn-ADFS-1.30.rom"
  -flop1 "$ARMEVAL_MEDIA/armevaluationsystem-disc3.adl"
  -artwork_crop
)
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" bbcb /data/assets-staging/armeval "$roms" \
    bbcb saa5050 bbc_tube_arm bbc_acorn1770
  mkdir -p "$ARMEVAL_MEDIA"
  install -m 644 /data/assets-staging/armeval/Acorn-ADFS-1.30.rom "$ARMEVAL_MEDIA/"
  install -m 644 /data/assets-staging/armeval/armevaluationsystem-disc3.adl "$ARMEVAL_MEDIA/"
  echo "  media staged: $ARMEVAL_MEDIA (ADFS 1.30 + disc3.adl)"
}

# Cold boot reaches "ARM Second Processor 4096K / Acorn ADFS / BASIC" + the
# A* prompt; white on black, so a non-black floor is the smoke check. The
# tube boot is slower than the plain Model B — give it 20 emulated seconds.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 2000 20
}
