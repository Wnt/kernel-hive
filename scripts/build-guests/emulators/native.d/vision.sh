# shellcheck shell=bash
# native.d/vision.sh — host-native stanza for VisiCorp Visi On 1.0 (1983),
# the vision station's `mame` race stream (RACE RUNNER A, sonnet). Driver
# ibm5160 lives in pc/ibmpc.cpp. Confirmed on THIS 0.289 build (2026-09-13)
# via -listxml/-listslots/-listroms:
#   - ibm5160's COMP() flags are 0 (status=good) — no skip-warnings would be
#     strictly required by the driver's own MACHINE_NOT_WORKING/IMPERFECT
#     flags, but the patch is kept anyway (harmless, matches the brief and
#     protects a headless kiosk from any sub-device warning panel).
#   - isa2's "com" card exposes the msystems mouse at
#     isa2:com:serport0 msystems_mouse (Mouse Systems Non-rotatable HLE).
#   - isa4's "hdc" slot option is the Fixed Disk Controller Card; its
#     ROM/device XML name is "isa_hdc" (NOT "hdc" — the slot OPTION and the
#     XML MACHINE name differ; stage-romset.py needs the XML name).
#   - The keyboard is its own romset "kb_pcxt83" (4584751.m1, the 8048 MCU
#     dump) — omitting it from the stage-romset call fails the boot gate
#     ("4584751.m1 NOT FOUND").
NATIVE_DRIVER=ibm5160
NATIVE_SUBTARGET=vision
NATIVE_SOURCES=src/mame/pc/ibmpc.cpp
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=(-isa1 cga -isa2 com -isa3 fdc_xt -isa4 hdc -isa2:com:serport0 msystems_mouse)
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  # ibm5160.zip + isa_hdc.zip from archive.org's MAME_0.278_ROMs_non-merged_2025
  # set (sha1-matched by stage-romset.py, so the exact zip vintage does not
  # matter — these are decades-old fixed ROM chip dumps). Staged flat under
  # race/mame/roms-flat/ by race runner A; NOT /data/assets-staging/vision
  # (that mount was unstable/refreshing during the race and is the media
  # agent's own dir besides — never write there).
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" ibm5160 /data/vms/sandbox/vision/race/mame/roms-flat "$roms" \
    ibm5160 isa_hdc kb_pcxt83
}

# XT BIOS draws the memory-count text quickly on a cold boot; MEASURED
# 2026-09-13 on this build: 1246 lit pixels at -str 15 (floor 200 from the
# brief holds with margin).
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 200 15
}
