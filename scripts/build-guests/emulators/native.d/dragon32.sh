# shellcheck shell=bash
# native.d/dragon32.sh — host-native conversion stanza for the Dragon 32, the
# campaign's TEMPLATE station (DEBRIDGE-CONVERSION-BRIEF.md §3 #1). Sourced by
# build-mame-native.sh; not executable on its own.
#
# THE ONE FLAG THAT MUST NOT DRIFT: `-ext ""`. MAME's dragon32 defaults its
# `ext` slot to dragon_fdc, and with it populated the machine boots DRAGONDOS
# 1.0 instead of Microsoft BASIC — the wrong exhibit in the same two greens.
# Every gate run below carries it, exactly like the kiosk launcher it replaces.
#
# ROM pins are the SAME as tiles/dragon32.sh (the bridge-era builder this
# stanza replaces at cutover): one 16 KB blob fetched by SHA, presented to
# 0.289 as the two 8 KB chip-designation halves its listxml declares. Assemble
# BY SHA1, never by filename — 0.276 called the same bits `d32.rom`.

NATIVE_DRIVER=dragon32
NATIVE_SUBTARGET=dragon
NATIVE_SOURCES=src/mame/trs/dragon.cpp
# The station's published surface: the kiosk drew MAME fullscreen with aspect
# correction on a 1024x768 X root, and a converted station keeps its geometry.
NATIVE_GEOM=1024x768
NATIVE_MAME_ARGS=(-ext "")
NATIVE_EXTRA_PATCHES=() # driver status=good: it never nags, no skip-warnings

DRAGON32_ROM_URL="https://archive.org/download/MAME_0.224_ROMs_merged/dragon32.zip/d32.rom"
DRAGON32_ROM_SHA1=f2dab125673e653995a83bf6b793e3390ec7f65a
DRAGON32_HALF0_NAME=dragon_data_ltd_1-0.ic18
DRAGON32_HALF0_SHA1=9fbba5128b8a53c65ee0586c10513a0a6fb05a7d
DRAGON32_HALF1_NAME=dragon_data_ltd_1-1.ic17
DRAGON32_HALF1_SHA1=7088d75995cc2ec80a7eed9b9cc3d62f0f820a43

native_stage_roms() {
  local roms="$1"
  local staging=/data/assets-staging/dragon32
  local blob="$staging/d32.rom"
  if [ ! -s "$blob" ] || [ "$(sha1sum "$blob" | awk '{print $1}')" != "$DRAGON32_ROM_SHA1" ]; then
    mkdir -p "$staging"
    curl -fsSL --retry 3 --max-time 300 -o "$blob" "$DRAGON32_ROM_URL" ||
      die "could not fetch d32.rom from $DRAGON32_ROM_URL"
    [ "$(sha1sum "$blob" | awk '{print $1}')" = "$DRAGON32_ROM_SHA1" ] ||
      die "fetched d32.rom SHA1 does not match the MAME pin $DRAGON32_ROM_SHA1"
  fi
  mkdir -p "$roms/dragon32"
  dd if="$blob" of="$roms/dragon32/$DRAGON32_HALF0_NAME" bs=8192 count=1 status=none
  dd if="$blob" of="$roms/dragon32/$DRAGON32_HALF1_NAME" bs=8192 skip=1 count=1 status=none
  [ "$(sha1sum "$roms/dragon32/$DRAGON32_HALF0_NAME" | awk '{print $1}')" = "$DRAGON32_HALF0_SHA1" ] ||
    die "romset half 0 SHA1 mismatch after split"
  [ "$(sha1sum "$roms/dragon32/$DRAGON32_HALF1_NAME" | awk '{print $1}')" = "$DRAGON32_HALF1_SHA1" ] ||
    die "romset half 1 SHA1 mismatch after split"
  echo "  romset staged: $roms/dragon32 ($DRAGON32_HALF0_NAME + $DRAGON32_HALF1_NAME, sha1-gated)"
}

# The boot gate reads the scene off the DRAWSHM mapping itself — the exact
# surface the converted station will stream — and asserts the same two things
# the kiosk build always asserted, because the failure they guard against
# (DRAGONDOS instead of BASIC) is the same two greens to a histogram:
#   * OCR tokens MICROSOFT + DATA + 1.0 present, DRAGONDOS absent — the only
#     words tesseract has never mangled on this blocky 8x12 font;
#   * text-ink floor in the banner band, immune to OCR. drawshm renders the
#     banner BYTE-IDENTICALLY to the kiosk's X root (measured 2026-08-12:
#     exactly the kiosk's 6376 px of 0,124,0 in 1024x230+0+60), so the floor
#     is the kiosk gate's own 3000 — between BASIC's 6376 and DRAGONDOS's
#     ~1170 with room on both sides.
# The shm pixels go through python straight to P6 — `convert bgra:`-style raw
# decoding was tried first and silently crushed the channels ~128:1 while
# keeping the LAYOUT intact, which passed OCR and zeroed the ink count.
native_boot_gate() {
  local bin="$1" roms="$2" gate="$3"
  local ink text token
  rm -rf "$gate"
  mkdir -p "$gate/cfg" "$gate/nvram"
  # 15 emulated seconds, unthrottled; the banner is up in ~2.
  (cd "$gate" && MAME_SHM_PATH="$gate/fb.shm" MAME_SHM_SIZE=$NATIVE_GEOM \
    "$bin" dragon32 -rompath "$roms" -ext "" \
    -video shm -sound none -nothrottle -str 15 -skip_gameinfo \
    -homepath . -cfg_directory ./cfg -nvram_directory ./nvram -inipath . \
    >"$gate/mame.log" 2>&1) || die "gate MAME exited non-zero; see $gate/mame.log"
  python3 - "$gate/fb.shm" "$gate/frame.ppm" <<'PY' || die "drawshm mapping unreadable"
import struct
import sys

b = open(sys.argv[1], "rb").read()
magic, _ver, w, h, stride, _bpp = struct.unpack_from("<6I", b, 0)
if magic != 0x31424649:
    sys.exit("bad drawshm magic")
out = bytearray()
for y in range(h):
    row = b[64 + y * stride : 64 + y * stride + w * 4]
    for x in range(0, w * 4, 4):
        out += bytes((row[x + 2], row[x + 1], row[x]))
open(sys.argv[2], "wb").write(b"P6\n%d %d\n255\n" % (w, h) + bytes(out))
PY
  convert "$gate/frame.ppm" "$gate/frame.png"
  convert "$gate/frame.ppm" -crop 1024x230+0+60 +repage "$gate/band.ppm"
  ink=$(ppmhist "$gate/band.ppm" 2>/dev/null |
    awk '$1" "$2" "$3 == "0 124 0" { print $5; f = 1 } END { if (!f) print 0 }')
  # 40% threshold: the MC6847's bright-green page sits at luma ~117 and its
  # dark-green text at ~34 (measured on the kiosk's own dump; 50% swallows
  # the page and tesseract sees nothing).
  convert "$gate/frame.png" -colorspace Gray -threshold 40% -negate "$gate/ocr.png"
  text=$(tesseract "$gate/ocr.png" - --psm 6 2>/dev/null | tr -d '\r' | tr '[:lower:]' '[:upper:]')
  case "$text" in
    *DRAGONDOS*)
      die "boot gate: framebuffer shows DRAGONDOS — the ext slot is populated;
  the gate lost its -ext \"\" (see $gate/frame.png)"
      ;;
  esac
  for token in MICROSOFT DATA "1.0"; do
    case "$text" in
      *"$token"*) ;;
      *) die "boot gate: OCR did not find '$token' in the banner (ink=$ink px);
  look at $gate/frame.png, not the log. OCR read: $text" ;;
    esac
  done
  [ "${ink:-0}" -ge "${MIN_BANNER_INK:-3000}" ] ||
    die "boot gate: banner ink $ink px < floor ${MIN_BANNER_INK:-3000} while OCR passed —
  drawshm is rendering the banner differently than the kiosk did; look at $gate/frame.png"
  echo "  boot gate PASSED: Microsoft BASIC banner on the drawshm frame"
  echo "  ($gate/frame.png; banner ink $ink px, kiosk reference 6376)"
}
