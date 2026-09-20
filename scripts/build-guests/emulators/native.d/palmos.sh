# shellcheck shell=bash
# native.d/palmos.sh — host-native conversion stanza for Palm OS 2.0
# Professional (English) on a PalmPilot Professional (MAME driver `palmpro`,
# mame/palm/palm.cpp).
#
# WHY palmpro AND NOT palmiii. The wave opened on `palmiii` because it is one
# of the Palm targets that ships MACHINE_SUPPORTS_SAVE with no working-flag
# caveat. It boots — but it never displays: MEASURED 2026-09-20, Palm OS 3.0
# and 3.3 draw the "Palm Computing Platform" splash into the framebuffer in
# guest RAM and then leave the MC68328's LCD controller DISABLED (LCKCON at
# 0xfffa27 settles on 0x58, bit 7 LCDON clear) and park the CPU in a STOP
# loop forever. Every published pixel is then the mc68328lcd device's literal
# LCD_OFF colour (0xbd,0xbd,0xaa) — a screen that is uniformly "lit" by pixel
# count and completely blank to a visitor. Palm OS 2.0 Professional on the
# same MC68328 hardware settles LCKCON on 0xd8 (LCDON set) and renders, so the
# station ships the OS that this emulation actually displays. palmiii/3.x is
# a genuine MAME gap, documented in docs/lab/PALMOS-WAVE.md.
#
# ROM: palmos20-en-pro.rom, 1048576 B, sha1
# 535bd9548365d300f85f514f318460443a021476 — a byte-exact match for the
# 2.0epro BIOS option inside the PALM_68328_BIOS macro (mame/palm/palm.cpp),
# sourced as Palm-OS-2.0-Pro-en.rom from palmdb.net's palm-roms-complete
# collection. ENGLISH, so the station carries no locale caveat.
#
# POINTER: Palm's pen is IPT_LIGHTGUN_X/Y, a true ABSOLUTE analog ioport
# field (PORT_MINMAX(0,0xa0)), not a relative counter like every other MAME
# station's mouse. mame-ctlsock-abs-fields.patch adds MAME_CTL_ABS=1: MOVEA
# writes m_x_field/m_y_field directly, scaled from the published surface into
# the field's own range — no accumulator, no cursor readback, because there
# is no on-screen cursor to converge against. That patch also carries the
# absolute-axis BINDING fallback without which the handles stay null on this
# machine (ptr-tags matches IPT_MOUSE_X/Y only) and every MOVEA acks OK while
# the pen never moves — MEASURED on palmpro, 2026-09-20.

NATIVE_DRIVER=palmpro
NATIVE_SUBTARGET=palmos
NATIVE_SOURCES=src/mame/palm/palm.cpp
# Published surface = the driver's own visarea (160x220). The LCD itself is
# only the top 160x160; rows 160..219 are the printed Graffiti silkscreen,
# which is unlit on real hardware too but IS part of the digitizer, so the
# Applications/Menu/Calculator/Find buttons down there are tappable.
NATIVE_GEOM=160x220
NATIVE_MAME_ARGS=(-bios 2.0epro)
NATIVE_EXTRA_PATCHES=(mame-ctlsock-ptr-tags.patch mame-ctlsock-abs-fields.patch)
# palmpro carries MACHINE_SUPPORTS_SAVE and no imperfect/not-working flag, so
# there is no modal startup warning to suppress.
NATIVE_SKIP_WARNINGS=0

native_stage_roms() {
  local roms="$1"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" palmpro /data/assets-staging/palmos/roms "$roms" \
    palmpro
}

# The fleet's native_gate_nonblack counts LIT pixels, and on this machine a
# DEAD LCD is uniformly "lit" (see the LCKCON note above): the 3.3 build
# passed that gate at 35200/35200 pixels while showing a visitor nothing.
# So this station's gate demands what a lit LCD actually produces — MORE THAN
# ONE distinct colour on the published surface.
native_boot_gate() {
  local bin="$1" roms="$2" gate="$3" colours
  rm -rf "$gate"
  mkdir -p "$gate/cfg" "$gate/nvram"
  (cd "$gate" && MAME_SHM_PATH="$gate/fb.shm" MAME_SHM_SIZE="$NATIVE_GEOM" \
    "$bin" "$NATIVE_DRIVER" -rompath "$roms" "${NATIVE_MAME_ARGS[@]}" \
    -video shm -sound none -nothrottle -str 12 -skip_gameinfo \
    -homepath . -cfg_directory ./cfg -nvram_directory ./nvram -inipath . \
    >"$gate/mame.log" 2>&1) || die "gate MAME exited non-zero; see $gate/mame.log"
  colours=$(
    python3 - "$gate/fb.shm" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
magic, _v, w, h, stride, _bpp = struct.unpack_from("<6I", b, 0)
if magic != 0x31424649:
    sys.exit("bad drawshm magic")
seen = set()
for y in range(h):
    row = b[64 + y * stride : 64 + y * stride + w * 4]
    for x in range(0, w * 4, 4):
        seen.add(row[x : x + 3])
print(len(seen))
PY
  ) || die "drawshm mapping unreadable; see $gate/mame.log"
  [ "$colours" -ge 2 ] ||
    die "smoke gate: the published surface is ONE flat colour ($colours distinct) —
     the MC68328 LCD controller never turned on; see $gate/mame.log"
  echo "  smoke gate PASSED: $colours distinct colours on the published surface (floor 2)"
}
