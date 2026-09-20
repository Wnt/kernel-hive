#!/bin/bash
# FIXED 2026-09-20: this script's KBD_MCU_* block used to fetch
# kaypro10kbd.zip/m5l8049.bin, which is WRONG for the fleet-pinned mame0289
# binary (native.d/cpm22.sh carries the same fix, see its comment) — the
# 0.289 tree wants kayproiikbd.zip/kaypro_ii-ins8048.bin instead (1024
# bytes, CRC f65e1ca5, sha1 7919385fe8badbb610b793a3f5e4077982094aaa).
# Sourced from archive.org item "mame-roms-split" ("MAME 0.280 ROMs
# (split)"), which serves each romset as a plain file (no zip-in-zip
# view_archive.php path, unlike the "mame-bios-devices" mega-zip that 503'd
# and then 404'd on the exact member path at the first attempt) —
# kayproiikbd.zip there hashes sha256
# 5a9825ca30f2b86f65d91b788378e592ce1c6c0a8f879b279de08b24fc2d8956
# (sha1 32ce9c4f80ea90776a06dbb8a367342b111cc3ec, matching the item's own
# metadata), and its one member `kaypro_ii-ins8048.bin` verifies against the
# sha1/CRC above. ***
#
# Stage the cpm22 station's media and ROMs: a Kaypro II CP/M 2.2 boot floppy
# and a WordStar 3.3 application floppy (Teledisk/ImageDisk preservation
# images, fed straight into MAME's NATIVE .td0/.imd reader — see below for
# why this station does NOT convert them to a raw/headerless .kay first),
# plus the kayproii/kaypro10kbd ROM set the driver needs.
#
# Owned by the cpm22 wave's `media` stream (docs/lab/CPM22-WAVE.md). It
# touches media/ROM staging only: the native/emulator plane is
# scripts/build-guests/emulators/native.d/cpm22.sh, the runtime fixture is
# streamhost/stations/cpm22/station.env.fixture, and the SPA copy is the spa
# stream's.
#
# WHY NOT CONVERT TO RAW (measured 2026-09-20, sandbox smoke stream):
# `dsktrans -itype tele -otype raw` on the CP/M boot TD0 produces a
# 204800-byte file (exactly 40 tracks * 10 sectors * 512 bytes, matching
# formats/kaypro_dsk.cpp's kayproii_format geometry) with NO read errors, but
# booting it froze at the ROM's "Please place your diskette into Drive"
# banner forever — libdsk's raw driver writes sectors in PHYSICAL encounter
# order (it printed IDs 002..011 per track), not the LOGICAL 1..10 order
# kayproii_format's header-less dump format requires, so the disk looks
# unformatted to the ROM. MAME 0.276 (and every 0.28x on this box) reads
# .td0/.imd NATIVELY (see -listmedia), sector-addressed through libretro's
# own TD0/IMD parsers, which get the logical order right — so this builder
# ships the untouched preservation images and lets MAME do the conversion at
# load time. A cold boot with the plain .td0 landed on the real "KAYPRO CP/M
# 2.2 (GMv2.72)" `A>` prompt with a live directory listing, and a scripted
# `DIR\n` through MAME's natural keyboard re-ran the listing cleanly.
#
# Usage: cpm22.sh [--force] [--no-gate]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OS_ID="cpm22"

STAGE_DIR="${STAGE_DIR:-/data/assets-staging/$OS_ID/media}"
ROM_DIR="${ROM_DIR:-/data/assets-staging/$OS_ID/roms}"
INSTALL_DIR="${INSTALL_DIR:-/data/vms/streamhost/assets/$OS_ID/media}"
ROM_INSTALL_DIR="${ROM_INSTALL_DIR:-/data/vms/streamhost/assets/$OS_ID/roms}"
WORK="${WORK:-/data/vms/build-cpm22-media}"
# The boot gate below must run the SAME binary that ships (the fleet-pinned
# mame0289 host-native build, scripts/build-guests/emulators/native.d/
# cpm22.sh), not a stock Debian MAME system package -- a stock 0.276
# package resolves this driver's keyboard through a DIFFERENT device
# (kaypro10kbd/m5l8049.bin) than 0.289 does (kayproiikbd/
# kaypro_ii-ins8048.bin), so a gate against the wrong binary would prove
# nothing about what actually ships (docs/lab/CPM22-WAVE.md).
MAME="${MAME:-/data/vms/streamhost/assets/$OS_ID/mame-native/kayproii}"
GATE=1
[[ "${1:-}" == "--no-gate" || "${2:-}" == "--no-gate" ]] && GATE=0

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

fetch_pinned() {
  local url="$1" sha="$2" dest="$3"
  if [[ -f "$dest" ]]; then
    local have
    have="$(sha256sum "$dest" | awk '{print $1}')"
    if [[ "$have" == "$sha" ]]; then
      log "already staged, sha256 matches: $(basename "$dest")"
      return 0
    fi
    log "staged $(basename "$dest") has wrong sha256 ($have) -- refetching"
    rm -f "$dest"
  fi
  log "fetching $(basename "$dest")"
  curl -fsSL -o "$dest.part" "$url" || die "fetch failed: $url"
  local got
  got="$(sha256sum "$dest.part" | awk '{print $1}')"
  [[ "$got" == "$sha" ]] || die "sha256 mismatch for $(basename "$dest"): got $got want $sha"
  mv "$dest.part" "$dest"
}

# ------------------------------------------------------------------ media --
# TOSEC "Kaypro II" preservation set (2012-04-23), archive.org item
# Kaypro_II_TOSEC_2012_04_23 -- one outer zip holding the whole set,
# organised by media type. The CP/M boot disk lives under the folder TOSEC
# LABELS "[IMD]" but the actual member is a .td0 (a TOSEC cataloguing quirk,
# not a bug here); WordStar's own entry under "Applications" IS a real .imd.
TOSEC_URL="https://archive.org/download/Kaypro_II_TOSEC_2012_04_23/Kaypro_II_TOSEC_2012_04_23.zip"
TOSEC_SHA256="c0da43cd9fd4aeb91b78e2374582cbad80f663722db976c65a0e3535e799db17"
TOSEC_FILE="Kaypro_II_TOSEC_2012_04_23.zip"
CPM_MEMBER="Kaypro II [TOSEC]/Kaypro II - Operating Systems - [IMD] (TOSEC 2012-02-27)/CP-M 2.2 Boot Disk (19xx)(Digital Research)(DE).zip"
WS_MEMBER="Kaypro II [TOSEC]/Kaypro II - Applications (TOSEC 2012-02-27)/WordStar v3.3 (1983)(MicroPro).zip"

# ------------------------------------------------------------------- roms --
# Board 81-110 BIOS. The DEFAULT bios (81-149.u47, CRC 28264bc1, no letter
# suffix) has no surviving dump on any mirror checked 2026-09-20 -- ship
# "149c" (81-149c.u47), the same revision archive.org's dedicated
# "81149c_KayproII_ROM" item preserves, on the same board family.
ROM_149C_URL="http://www.retroarchive.org/maslin/roms/kaypro/81-149c.rom"
ROM_149C_SHA256="5231e5dd0f6fb64a8ec50951269c248e00875906e391d044918e212d14b08f55"
ROM_146A_URL="http://www.retroarchive.org/maslin/roms/kaypro/81-146a.rom"
ROM_146A_SHA256="cde431c9e506edf11261f7e7d52fd60b1a43fe2d9ea0d3e06f271d4cab4884fa"
# The Kaypro II keyboard's Intel i8048 MCU dump, a SEPARATE MAME device
# romset (kayproiikbd, devices/bus/keytronic/keytronic_l2207.cpp) this
# driver's keyboard connector needs alongside its own kayproii.zip --
# MEASURED 2026-09-20 against the actual fleet-pinned mame0289 binary:
# MAME refuses to run without it ("kaypro_ii-ins8048.bin NOT FOUND (tried
# in kayproiikbd kayproii)"). A STOCK MAME 0.276 system package resolves
# this keyboard through a DIFFERENT device (kaypro10kbd/m5l8049.bin) --
# that is a smoke-test artifact only, never what ships; trust -listxml on
# the binary that will actually run. TorrentZipped member from the
# Internet Archive's "MAME 0.280 ROMs (split)" set (mame-roms-split item),
# which serves each romset as a plain downloadable file.
KBD_MCU_URL="https://archive.org/download/mame-roms-split/MAME%20ROMs%20%28split%29/kayproiikbd.zip"
KBD_MCU_SHA256="5a9825ca30f2b86f65d91b788378e592ce1c6c0a8f879b279de08b24fc2d8956"

mkdir -p "$STAGE_DIR" "$ROM_DIR" "$WORK"

fetch_pinned "$TOSEC_URL" "$TOSEC_SHA256" "$WORK/$TOSEC_FILE"
rm -rf "$WORK/tosec-extract"
mkdir -p "$WORK/tosec-extract"
unzip -oq "$WORK/$TOSEC_FILE" -d "$WORK/tosec-extract"
unzip -oq "$WORK/tosec-extract/$CPM_MEMBER" -d "$WORK/cpm-extract"
unzip -oq "$WORK/tosec-extract/$WS_MEMBER" -d "$WORK/ws-extract"
CPM_TD0="$(find "$WORK/cpm-extract" -iname '*.td0' | head -1)"
WS_IMD="$(find "$WORK/ws-extract" -iname '*.imd' | head -1)"
[[ -n "$CPM_TD0" ]] || die "CP/M boot disk .td0 missing from the TOSEC extract"
[[ -n "$WS_IMD" ]] || die "WordStar .imd missing from the TOSEC extract"
cp -f "$CPM_TD0" "$STAGE_DIR/cpm22-boot.td0"
cp -f "$WS_IMD" "$STAGE_DIR/wordstar33.imd"

fetch_pinned "$ROM_149C_URL" "$ROM_149C_SHA256" "$ROM_DIR/81-149c.rom"
fetch_pinned "$ROM_146A_URL" "$ROM_146A_SHA256" "$ROM_DIR/81-146a.rom"
fetch_pinned "$KBD_MCU_URL" "$KBD_MCU_SHA256" "$WORK/kayproiikbd.zip"
unzip -oq "$WORK/kayproiikbd.zip" -d "$WORK/kbd-extract"
cp -f "$WORK/kbd-extract/kaypro_ii-ins8048.bin" "$ROM_DIR/kaypro_ii-ins8048.bin"

(cd "$STAGE_DIR" && sha256sum -- *.td0 *.imd >MANIFEST.sha256) || true
(cd "$ROM_DIR" && sha256sum -- *.rom *.bin >MANIFEST.sha256) || true

# --------------------------------------------------------------- boot gate --
if [[ "$GATE" == 1 ]]; then
  log "boot gate: cold-booting the CP/M boot disk and checking the frame"
  ROMPATH="$WORK/roms"
  mkdir -p "$ROMPATH/kayproii" "$ROMPATH/kayproiikbd" "$WORK/proof"
  cp -f "$ROM_DIR/81-149c.rom" "$ROMPATH/kayproii/81-149c.u47"
  cp -f "$ROM_DIR/81-146a.rom" "$ROMPATH/kayproii/81-146.u43"
  cp -f "$ROM_DIR/kaypro_ii-ins8048.bin" "$ROMPATH/kayproiikbd/kaypro_ii-ins8048.bin"
  cat >"$WORK/boot-gate.lua" <<'LUAEOF'
local function snap() manager.machine.video:snapshot() end
emu.wait(6)
snap()
LUAEOF
  rm -rf "$WORK/snap"
  MAME_BIN="$MAME"
  [[ -x "$MAME_BIN" ]] || die "$MAME_BIN not found -- run build-mame-native.sh cpm22 first (native.d/cpm22.sh)"
  (cd "$WORK" && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "$MAME_BIN" kayproii -bios 149c \
    -rompath "$ROMPATH" -homepath . -cfg_directory ./cfg -nvram_directory ./nvram -inipath . \
    -snapshot_directory ./snap -flop1 "$STAGE_DIR/cpm22-boot.td0" -skip_gameinfo -video soft \
    -window -nothrottle -autoboot_delay 1 -autoboot_script boot-gate.lua -seconds_to_run 10 \
    -sound none >mame.log 2>&1) || die "boot gate: MAME run failed; see $WORK/mame.log"
  GATE_PNG="$WORK/snap/kayproii/0000.png"
  [[ -f "$GATE_PNG" ]] || die "boot gate: MAME wrote no frame"
  python3 - "$GATE_PNG" <<'PYEOF' || die "boot gate: the CP/M banner frame is blank"
import sys
import zlib

data = open(sys.argv[1], "rb").read()
pos, chunks, w, h = 8, [], 0, 0
while pos < len(data):
    ln = int.from_bytes(data[pos:pos + 4], "big")
    tag = data[pos + 4:pos + 8]
    body = data[pos + 8:pos + 8 + ln]
    if tag == b"IHDR":
        w = int.from_bytes(body[0:4], "big")
        h = int.from_bytes(body[4:8], "big")
    elif tag == b"IDAT":
        chunks.append(body)
    pos += 12 + ln
raw = zlib.decompress(b"".join(chunks))
lit = sum(1 for i in range(0, len(raw), 64) if raw[i] > 24)
print("[build:cpm22] gate frame %dx%d, %d/%d sampled bytes lit"
      % (w, h, lit, len(raw) // 64 + 1), file=sys.stderr)
sys.exit(0 if lit > 20 else 1)
PYEOF
  cp -f "$GATE_PNG" "$WORK/proof/01-boot-banner.png"
  log "boot gate passed -- $WORK/proof/01-boot-banner.png"
fi

# --------------------------------------------------------------- install ---
mkdir -p "$INSTALL_DIR" "$ROM_INSTALL_DIR"
cp -f "$STAGE_DIR/cpm22-boot.td0" "$INSTALL_DIR/cpm22-boot.td0"
cp -f "$STAGE_DIR/wordstar33.imd" "$INSTALL_DIR/wordstar33.imd"
log "installed $INSTALL_DIR/cpm22-boot.td0 ($(stat -c %s "$INSTALL_DIR/cpm22-boot.td0") bytes, sha256 $(sha256sum "$INSTALL_DIR/cpm22-boot.td0" | awk '{print $1}'))"
log "installed $INSTALL_DIR/wordstar33.imd ($(stat -c %s "$INSTALL_DIR/wordstar33.imd") bytes, sha256 $(sha256sum "$INSTALL_DIR/wordstar33.imd" | awk '{print $1}'))"
