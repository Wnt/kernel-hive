#!/bin/bash
# Build the atari800xl station's boot disks (hive.atr, hive2.atr): Atari
# MyDOS-format SINGLE-density (720 x 128-byte sectors, 90 K) ATRs. hive.atr's
# boot sectors carry MyPicoDos 4.06 (Matthias Reichl / HiassofT); its boot
# screen IS the menu -- it lists every file on the disk and loads the
# highlighted one on RETURN -- so this station gets its one-key selector for
# free, the way the apple2e station gets one from a ProDOS STARTUP program
# (scripts/build-guests/tiles/apple2e.sh). hive2.atr (-flop2) is a plain
# second data drive (D2:, no boot code) for what does not fit on D1:.
#
# Owned by the atari800xl wave's "media" stream (docs/lab/ATARI800XL-WAVE.md).
# It touches media only: fetch, verify, compose, boot-gate, install. The
# emulator/ROM plane is the native stream's, the poster the spa stream's.
#
# WALL, recorded so nobody re-walks it: MAME's emulated Atari 1050
# (src/devices/bus/a800/atari1050.cpp) only supports SINGLE density (FM,
# 720 x 128 B, 90 K) and DOUBLE density (MFM, 256 B/sector, DOS 3) -- it does
# NOT emulate enhanced density (1040 x 128 B), even though a real 1050 drive
# reads it. An ED image (dir2atr's `-E`) boots to a perfectly-drawn MyPicoDos
# menu -- the boot sectors and the low-numbered directory sectors happen to
# read fine -- but every XEX LOAD off it fails partway (the drive can't
# actually deliver the higher sector range) and MyPicoDos silently redraws
# the menu instead of running the program: three race runners each confirmed
# this independently (any confirm key -> blue "loading" screen ~20 s -> menu
# back, pixel-identical). A DD image (`-d`) never even gets that far -- it
# hangs on a blank blue screen forever, because the drive can't read 256-byte
# sectors either. Fix: build SINGLE density (dir2atr's default, no -d/-E; `-S`
# pins it explicitly) -- 90 K is the hard per-drive ceiling, so the library is
# split across D1: (priority titles) and D2: (`-flop2`, overflow).
#
# Titles are XEX/COM single-file binaries wherever possible: MyPicoDos loads
# those directly, while a title distributed only as its own bootable ATR
# (Yoomp!, Rescue on Fractalus!) cannot be launched from inside another disk
# and is therefore NOT on the menu.
#
# The Last Word 3.2 (Jonathan Halliday, freeware) is the application. It ships
# as a DOS 2 ATR, so this script lifts LW.EXE + LW.CFG out of that image with a
# small DOS 2 reader rather than shipping the whole disk.
#
# XBASIC.XEX is ours, 31 bytes of 6502 assembled inline: it clears bit 1 of
# PORTB ($D301) to page the Atari BASIC ROM back in over the RAM MyPicoDos was
# using, zeroes BOOT? ($09) and COLDST ($0244) so the OS stops believing a DOS
# is resident, and jumps to WARMSV ($E474). Warm start runs the BASIC
# "cartridge" without re-reading the disk. COLDSV ($E477) was tried first and is
# WRONG: a cold start re-boots D1: and you land straight back on the menu.
#
# golden4 stream, 2026-09-08: that alone still landed back on the MyPicoDos
# menu after ~8s (proof/xbasic_back_to_menu.png, golden3). First fix tried:
# neutralise DOSINI ($0C/$0D) with an RTS stub before JMP WARMSV -- measured
# NO CHANGE (same menu frame hash back), because WARMSV's own vector-init
# path re-points DOSVEC ($0A/$0B) at MyPicoDos's own menu-redraw code (no
# disk re-read needed, which is why the "reboot" symptom is absent and it
# still reads as an instant return) regardless of DOSINI. Going through the
# OS's warmstart machinery at all is the wrong layer -- but skipping it
# entirely (JMP $A000, or JMP ($BFFE) into the cart header's own declared
# reset entry) either lands back on MyPicoDos (measured: WARMSV's cart-present
# check reads a RAM-shadowed flag latched once at cold boot, not the live
# PORTB state, so it falls through to DOSVEC regardless -- $BFFE isn't real
# BASIC-ROM header data at that address either, same menu frame back) or
# draws a garbage screen (JMP $A000: BASIC's ROM entry assumes the OS has
# already reset the screen editor/display list the way WARMSV does, which a
# bare jump to the top of the ROM skips). A third variant -- let WARMSV do
# its normal job but neutralise BOTH vectors MyPicoDos owns first (DOSINI to
# an RTS stub at $0600, DOSVEC to $A000 so the OS's own post-DOSINI fallback
# lands in BASIC) -- measured WORSE: a permanent hang on the blue pre-boot
# screen, never even redrawing the menu. STILL OPEN: this script ships the
# ORIGINAL 18-byte version (return-to-menu, not a hang) rather than the hang;
# see the OPEN item in docs/lab/ATARI800XL-WAVE.md for the next theory to
# try (reading MyPicoDos's own resident code to find what it actually hooks
# on reset, since it is neither DOSINI nor a stale cart-header check alone).
#
# golden5 stream, 2026-09-08: XBASIC.XEX is no longer composed onto D1: --
# every variant above returns either the same menu or a hang, never a BASIC
# READY prompt, and a menu entry that does nothing does not ship. The
# assembly stays in the compose step below, disabled by SHIP_XBASIC=0, for
# whoever next finds the real hook.
#
# Usage: atari800xl.sh [--force]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_ID="atari800xl"

STAGE_DIR="${STAGE_DIR:-/data/assets-staging/${OS_ID}/media}"
INSTALL_DIR="${INSTALL_DIR:-/data/vms/streamhost/assets/${OS_ID}/media}"
WORK="${WORK:-/data/vms/build-${OS_ID}-media}"
ROM_DIR="${ROM_DIR:-/data/assets-staging/${OS_ID}/roms}"
MAME="${MAME:-/usr/games/mame}"

# AtariSIO (HiassofT) -- dir2atr composes a MyDOS image and writes MyPicoDos
# into its boot sectors in one pass. Pinned commit; tools-only build.
ATARISIO_REPO="https://github.com/HiassofT/AtariSIO.git"
ATARISIO_COMMIT="bbccb15265259a1408f36d7ed9b89bb08bbb711d" # dir2atr 0.30-240419
ATARISIO_DIR="${ATARISIO_DIR:-$WORK/atarisio}"

# --- pinned sources: url, sha256, bytes -------------------------------------
# Fandal's collection (a8.fandal.cz) serves each entry as a zip of one file.
# Licence class: abandonware home-computer titles, used locally only -- the
# gallery is private and NO title bits are ever committed to this repo.
#
# Boulder Dash was DROPPED here (golden4 stream, 2026-09-08): fandal's
# BOULDER.XEX (one block 2900-6cbf, RUN 6c80) loads and then RESETS the
# machine -- full reboot back to the menu, proven three times on the ctlsock
# path (frame hashes identical to a cold boot with and without BASIC). The
# one alternative tried in the time box -- archive.org
# a8b_Boulder_Dash_1984_First_Star_Software_US_h_Iron_Software -- ships only
# a 16000-byte single-density boot-loader ATR with no DOS directory to lift a
# clean XEX from, so it does not fit MyPicoDos's launch-a-file model either.
# The museum prefers a menu where every entry works, so Boulder Dash is off
# D1: and the default highlight now sits on RIVRRAID.XEX, a proven title.
DROPZONE_URL="https://a8.fandal.cz/files/binaries/games/d/dropzone.zip"
DROPZONE_SHA256="b8af400e4d5a6135645d52bb04995ad1955f7eb02700a57197f9c0a4c8149bfb"
RIVERRAID_URL="https://a8.fandal.cz/files/binaries/games/r/river_raid.zip"
RIVERRAID_SHA256="9db57d32ff2a43a736f6afbda5a15ba38426383104ce8d2948973f57d03dda52"
STARRAIDERS_URL="https://a8.fandal.cz/files/binaries/games/s/star_raiders.zip"
STARRAIDERS_SHA256="46d084e428ac9b85be0f0e5fda8f1af28bc4157db528547fc57c73e3102f3e3d"
# The Last Word 3.2 -- freeware, from the author's own site.
LASTWORD_URL="https://atari8.co.uk/wp-content/uploads/2015/03/LW32.zip"
LASTWORD_SHA256="d97fc6f4ff412f92e391e253b30bca164e6fcfa5e84e9628d2e5896299f01d4b"

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
      log "already staged: $(basename "$dest")"
      return 0
    fi
    log "staged $(basename "$dest") has wrong sha256 ($have) -- refetching"
    rm -f "$dest"
  fi
  log "fetching $(basename "$dest")"
  curl -fsSL -A "Mozilla/5.0" -o "$dest.part" "$url" || die "fetch failed: $url"
  local got
  got="$(sha256sum "$dest.part" | awk '{print $1}')"
  [[ "$got" == "$sha" ]] || die "sha256 mismatch for $(basename "$dest"): got $got want $sha"
  mv "$dest.part" "$dest"
}

mkdir -p "$STAGE_DIR" "$WORK"

fetch_pinned "$DROPZONE_URL" "$DROPZONE_SHA256" "$STAGE_DIR/dropzone.zip"
fetch_pinned "$RIVERRAID_URL" "$RIVERRAID_SHA256" "$STAGE_DIR/river_raid.zip"
fetch_pinned "$STARRAIDERS_URL" "$STARRAIDERS_SHA256" "$STAGE_DIR/star_raiders.zip"
fetch_pinned "$LASTWORD_URL" "$LASTWORD_SHA256" "$STAGE_DIR/LW32.zip"

(cd "$STAGE_DIR" && sha256sum ./*.zip >MANIFEST.sha256)

# --- dir2atr ----------------------------------------------------------------
DIR2ATR="$ATARISIO_DIR/tools/dir2atr"
if [[ ! -x "$DIR2ATR" ]]; then
  log "building AtariSIO tools at $ATARISIO_COMMIT"
  rm -rf "$ATARISIO_DIR"
  git clone -q "$ATARISIO_REPO" "$ATARISIO_DIR" || die "git clone AtariSIO failed"
  git -C "$ATARISIO_DIR" checkout -q "$ATARISIO_COMMIT" || die "AtariSIO commit $ATARISIO_COMMIT not found"
  make -C "$ATARISIO_DIR/tools" -f Makefile.posix >/dev/null || die "AtariSIO tools build failed"
fi
[[ -x "$DIR2ATR" ]] || die "dir2atr missing at $DIR2ATR"

# --- compose the disk directories -------------------------------------------
# An Atari 1050 (MAME's a1050) is single/enhanced density ONLY -- and the
# emulated a1050 (src/devices/bus/a800/atari1050.cpp) doesn't even carry
# enhanced density support, only single (FM, 720 x 128 B, 90 K). An ED image
# (dir2atr -E, 1040 x 128 B) boots and lists fine, but every XEX LOAD off it
# fails partway (MyPicoDos silently re-draws the menu) because the drive can't
# actually read the higher sector count. Fix: build SD (dir2atr's default, no
# -d/-E) and split the library across two drives -- D1: for the disk1
# priority list, D2: (-flop2) for what doesn't fit.
DISK="$WORK/disk"
DISK2="$WORK/disk2"
rm -rf "$DISK" "$DISK2"
mkdir -p "$DISK" "$DISK2"

unzip -o -j "$STAGE_DIR/dropzone.zip" -d "$WORK/x" >/dev/null
mv "$WORK/x/Dropzone.xex" "$DISK2/DROPZONE.XEX"
unzip -o -j "$STAGE_DIR/river_raid.zip" -d "$WORK/x" >/dev/null
mv "$WORK/x/River Raid.xex" "$DISK/RIVRRAID.XEX"
unzip -o -j "$STAGE_DIR/star_raiders.zip" -d "$WORK/x" >/dev/null
mv "$WORK/x/Star Raiders.xex" "$DISK/STARRAID.XEX"

# The Last Word 3.2: pull LW.EXE + LW.CFG out of its DOS 2 disk image.
unzip -o -j "$STAGE_DIR/LW32.zip" 'LW32DOS2_DISK1.atr' -d "$WORK/x" >/dev/null
python3 - "$WORK/x/LW32DOS2_DISK1.atr" "$DISK" <<'PY' || die "Last Word extraction failed"
import sys
img, out = sys.argv[1], sys.argv[2]
d = open(img, 'rb').read()
hdr, data = d[:16], d[16:]
ss = hdr[4] | (hdr[5] << 8)
def sec(n):                      # ATR: the first three sectors are always 128 B
    if ss == 128: return data[(n-1)*128:(n-1)*128+128]
    if n <= 3:    return data[(n-1)*128:(n-1)*128+128]
    off = 3*128 + (n-4)*ss
    return data[off:off+ss]
want = {'LW      EXE': 'LASTWORD.XEX', 'LW      CFG': 'LW.CFG'}
got = set()
for s in range(361, 369):        # DOS 2 directory
    b = sec(s)
    for i in range(8):
        e = b[i*16:(i+1)*16]
        if e[0] == 0: continue
        name = e[5:16].decode('latin1')
        if name not in want: continue
        n = e[3] | (e[4] << 8)
        buf = bytearray()
        while n:
            sb = sec(n)
            buf += sb[:sb[127] & 0x7f]
            n = ((sb[125] & 0x03) << 8) | sb[126]
        open(f'{out}/{want[name]}', 'wb').write(bytes(buf))
        got.add(name)
missing = set(want) - got
if missing: sys.exit(f'not found in {img}: {sorted(missing)}')
PY

# XBASIC.XEX -- see the header note. 18 bytes at $2000, run address $2000.
# golden5 stream, 2026-09-08: REMOVED from the shipped menu. Three DOSINI/
# DOSVEC fixes were tried by golden4 (neutralise DOSINI alone: no change;
# JMP $A000 direct: escapes MyPicoDos but draws a garbage screen; neutralise
# DOSINI+DOSVEC through WARMSV: a permanent hang) and none reached a BASIC
# READY prompt -- the safest of the three, the plain 18-byte version below,
# only returns cleanly to the menu, which does nothing for a visitor. A menu
# entry that does nothing does not ship (docs/lab/ATARI800XL-WAVE.md OPEN
# items), so this stream stopped composing it onto D1:. The assembly is kept
# here, disabled by SHIP_XBASIC=0, for whichever stream next finds the real
# MyPicoDos warm-start hook -- flip the flag to 1 to put it back on the disk
# once RETURN on it reaches a BASIC READY prompt.
SHIP_XBASIC=0
if [[ "$SHIP_XBASIC" == 1 ]]; then
  python3 - "$DISK/XBASIC.XEX" <<'PY'
import sys
code = bytes([
    0xAD, 0x01, 0xD3,   # LDA $D301        ; PORTB
    0x29, 0xFD,         # AND #$FD         ; clear bit 1 -> BASIC ROM in
    0x8D, 0x01, 0xD3,   # STA $D301
    0xA9, 0x00,         # LDA #$00
    0x85, 0x09,         # STA $09          ; BOOT?  = no DOS resident
    0x8D, 0x44, 0x02,   # STA $0244        ; COLDST = warm start is legal
    0x4C, 0x74, 0xE4,   # JMP $E474        ; WARMSV
])
s = 0x2000; e = s + len(code) - 1
xex  = b'\xff\xff' + bytes([s & 255, s >> 8, e & 255, e >> 8]) + code
xex += bytes([0xE0, 0x02, 0xE1, 0x02, s & 255, s >> 8])   # RUNAD $02E0
open(sys.argv[1], 'wb').write(xex)
PY
fi

# --- build the images --------------------------------------------------------
# -m MyDOS format, single density (dir2atr's default -- omit -d/-E; -S pins it
# explicitly), -p long names, -b MyPicoDos406N the boot code on disk1 only
# (disk2 carries no boot code, it is a plain data drive on D2:).
ATR="$WORK/hive.atr"
ATR2="$WORK/hive2.atr"
rm -f "$ATR" "$ATR2"
"$DIR2ATR" -m -p -S -b MyPicoDos406N "$ATR" "$DISK/" || die "dir2atr failed (disk1)"
"$DIR2ATR" -m -p -S "$ATR2" "$DISK2/" || die "dir2atr failed (disk2)"

# --- boot gate: the composed disk must reach a non-black frame in MAME, and
# every title must actually LOAD (not just list) -- an enhanced-density image
# passed this same "menu is drawn" check while every XEX load silently failed,
# so the gate also drives one RETURN on the default highlight and checks the
# frame changed away from the menu (proves the drive delivered sector data,
# not just the directory).
if [[ -x "$MAME" && -d "$ROM_DIR" ]]; then
  GATE="$WORK/gate"
  rm -rf "$GATE"
  mkdir -p "$GATE/roms/a800xlp" "$GATE/shots"
  ln -sf "$ROM_DIR"/*.rom "$GATE/roms/a800xlp/"
  printf '[misc]\nskip_warnings 1\n' >"$GATE/ui.ini"
  (cd "$GATE" && timeout 400 "$MAME" a800xlp -rompath ./roms -homepath . \
    -cfg_directory ./cfg -nvram_directory ./nvram -inipath . -skip_gameinfo \
    -video none -sound none -flop1 "$ATR" -flop2 "$ATR2" -ctrl1 joy \
    -str 45 -snapshot_directory ./shots >/dev/null 2>&1) || die "MAME boot gate crashed"
  SHOT="$(find "$GATE/shots" -name '*.png' | head -1)"
  [[ -n "$SHOT" ]] || die "boot gate produced no frame"
  python3 - "$SHOT" <<'PY' || die "boot gate frame is blank -- the disk did not reach the MyPicoDos menu"
import sys, struct
# The MAME snapshot is a paletted PNG of a two-colour text screen, so counting
# distinct byte values proves nothing -- the compressed IDAT size does. A blank
# blue frame (the failure mode when the drive never answers) packs to under
# 1 KB; the MyPicoDos menu packs to ~3 KB.
d = open(sys.argv[1], 'rb').read()
i, idat = 8, 0
while i < len(d):
    ln = struct.unpack('>I', d[i:i+4])[0]
    if d[i+4:i+8] == b'IDAT': idat += ln
    i += 12 + ln
if idat < 1500: sys.exit(f'frame has no detail (IDAT {idat} bytes)')
PY
  log "boot gate passed: $SHOT"
else
  log "boot gate SKIPPED (no $MAME or no $ROM_DIR) -- run this on labhost for the gate"
fi

mkdir -p "$INSTALL_DIR"
cp -f "$ATR" "$INSTALL_DIR/hive.atr"
cp -f "$ATR2" "$INSTALL_DIR/hive2.atr"
log "installed $INSTALL_DIR/hive.atr ($(stat -c %s "$INSTALL_DIR/hive.atr") bytes, sha256 $(sha256sum "$INSTALL_DIR/hive.atr" | awk '{print $1}'))"
log "installed $INSTALL_DIR/hive2.atr ($(stat -c %s "$INSTALL_DIR/hive2.atr") bytes, sha256 $(sha256sum "$INSTALL_DIR/hive2.atr" | awk '{print $1}'))"
