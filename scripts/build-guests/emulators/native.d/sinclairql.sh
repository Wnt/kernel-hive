# shellcheck shell=bash
# native.d/sinclairql.sh — host-native conversion stanza for the Sinclair QL,
# the fleet's hardest romset (the brief's #8). The merged preservation zip is
# unzipped and sha1-matched against THIS binary's listxml; hal16l8.ic38 (the
# undumped PAL) must remain the ONLY missing member. The bridge's apt 0.251
# could not skip MAME's imperfect-dump warning, so its golden carried an 'x'
# keypress to dismiss it — this build ships skip-warnings and the panel
# never exists, which also retires the "zero leaked green glyphs" trap. The
# golden scene still needs F1 (the QL's monitor/TV chooser), sent through
# the ctlsock natural keyboard at cutover.

NATIVE_DRIVER=ql
NATIVE_SUBTARGET=ql
NATIVE_SOURCES=src/mame/sinclair/ql.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=()
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  local scratch="$WORK/sinclairql-staging"
  rm -rf "$scratch"
  mkdir -p "$scratch"
  unzip -o -q -j /data/assets-staging/sinclairql/ql-mame0224-merged.zip -d "$scratch"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" ql "$scratch" "$roms" ql
}

# Cold boot sits at the F1/F2 monitor-TV chooser — sparse text on black; the
# floor only proves the machine drew its prompt (no panel, no black stall).
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 1500 25
}
