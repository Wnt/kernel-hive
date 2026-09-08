#!/bin/bash
# Build the samcoupe station's boot floppy (hive.mgt): an 800K MGT disk that
# boots SAMDOS 2.0 and lands on a one-keypress SAM BASIC menu -- the SAM
# Coupe equivalent of the apple2e station's ProDOS STARTUP menu
# (scripts/build-guests/tiles/apple2e.sh) and the freedos station's MENU.BAT.
#
# Owned by the samcoupe wave's "media" stream (docs/lab/SAMCOUPE-WAVE.md). It
# touches media only: the emulator/ROM plane is the native stream's, the
# savestate is the golden stream's, the SPA copy is the spa stream's.
#
# HOW THE DISK IS PUT TOGETHER
#
# There is no Linux tool that writes a SAMDOS filesystem (SimCoupe ships none,
# samdisk copies raw sectors, pyz80 assembles rather than files), so this does
# it in two halves:
#
#   1. lib/mgtfs.py composes a FRESH 819200-byte image, copying whole files
#      out of the source disks -- SAMDOS 2.0 itself, then the titles -- with
#      their directory entries and 9-byte SAM headers intact. Allocation is
#      strictly sequential from track 4, so the sector address map is exact
#      by construction and there is no free list to corrupt.
#   2. The `auto` menu is a SAM BASIC program, and tokenizing SAM BASIC on the
#      host would mean writing a tokenizer. Instead MAME TYPES IT IN: the
#      composed disk is booted in stock MAME, the menu is keyed in line by
#      line by a Lua autoboot script, and `SAVE "auto" LINE 1` writes it to
#      the disk -- MAME's MGT floppy format saves changes back to the image
#      file, so the typed program lands in hive.mgt for real.
#
# Two traps cost real time here and are load-bearing, not decoration:
#   * The MGT boot screen EATS the first keypress, so every key sequence
#     starts with a bare newline. Without it "BOOT" arrives as "OOT", no DOS
#     loads, and `SAVE` silently goes to TAPE ("Start tape and then press a
#     key") instead of to the disk.
#   * SAM BASIC's line editor cannot keep up with MAME's natural-keyboard
#     posting rate. Typing the menu as one -autoboot_command string produces a
#     single mangled line with every ENTER lost; the Lua script paces one line
#     per emu.wait() instead.
#
# Usage: samcoupe.sh [--force] [--no-gate]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OS_ID="samcoupe"

STAGE_DIR="${STAGE_DIR:-/data/assets-staging/$OS_ID/media}"
ROM_DIR="${ROM_DIR:-/data/assets-staging/$OS_ID/roms}"
INSTALL_DIR="${INSTALL_DIR:-/data/vms/streamhost/assets/$OS_ID/media}"
WORK="${WORK:-/data/vms/sandbox/samcoupe-media/mame}"
MAME="${MAME:-/usr/games/mame}"
GATE=1
[[ "${1:-}" == "--no-gate" || "${2:-}" == "--no-gate" ]] && GATE=0

# Sources. The gallery is private, so the bits are never committed -- only the
# URL, size, sha256 and licence class live in the repo (ASSETS-MANIFEST.md).
SAMDOS_URL="https://www.worldofsam.org/system/files/2018-05/SAMDOSVersion2.0.dsk"
SAMDOS_SHA256="7e4de8ae3aef8bbe913ac55ddef320b45f67f8a4fa2778ee3f0391d1e39dfe60"
SAMDOS_FILE="SAMDOSVersion2.0.dsk"

# 5-in-1 Pack (Revelation Software, 1992) -- Manic Miner, Splat!, Mr. Pac,
# Snake Mania, Craft!. Ships as .sad (Aley's disk backup), which mgtfs.py
# detects and reads. Three of its five titles go on the hive disk.
FIVE_URL="https://archive.org/download/miles-gordon-technology-sam-coupe-champion-collection/Miles%20Gordon%20Technology%20SAM%20Coupe%20Champion%20Collection.zip/5-In-1%20Pack%20-%20Manic%20Miner%2C%20Splat%21%2C%20Mr.%20Pac%2C%20Snake%20Mania%2C%20and%20Craft%21%20%28EU%29.sad"
FIVE_SHA256="fdec2e69715dcaaed0241d876838a732fa6e8d6095eb0df947177300c7cfde67"
FIVE_FILE="5in1_ManicMiner_Splat_MrPac_SnakeMania_Craft.sad"

# The Secretary (word processor) -- the exhibit's application.
SEC_URL="http://ftp.nvg.ntnu.no/pub/sam-coupe/disks/utils/TheSecretary.zip"
SEC_SHA256="8597f1138ddca18a135b797f404376c296462cb31d987ff70853b00e232a607a"
SEC_FILE="TheSecretary.dsk"

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

# MAME lives on labhost, not in the CT950 build container, and $WORK is on the
# /data bind mount both can see -- so when the binary is not local the emulator
# runs through the one door (AGENTS.md rule 2) and reads/writes the same files.
REMOTE=0
if [[ ! -x "$MAME" ]]; then
  REMOTE=1
  ssh lab "test -x $MAME" || die "$MAME is on neither this host nor labhost"
  log "MAME runs on labhost (ssh lab); the disk images live on the shared /data mount"
fi
# MAME resolves ROMs as <rompath>/<setname>/..., so the staged flat rom dir is
# mirrored into $WORK/roms/samcoupe rather than passed directly.
# (the staging ROM dir is visible on labhost but not inside CT950, so the
# mirror is made wherever MAME is going to run)
ROMPATH="$WORK/roms"
mkdir -p "$STAGE_DIR" "$WORK"
if [[ "$REMOTE" == 1 ]]; then
  # MAME runs as root over the door, so anything a previous run (or a hand
  # driven proof) left behind is root-owned and this script cannot delete it.
  ssh lab "chown -R 1000:1000 $WORK" || die "could not take back $WORK on labhost"
  ssh lab "mkdir -p $ROMPATH/samcoupe && cp -f $ROM_DIR/*.z5 $ROMPATH/samcoupe/ && chown -R 1000:1000 $ROMPATH" ||
    die "no ROMs at $ROM_DIR on labhost (the spine stages them)"
else
  mkdir -p "$ROMPATH/samcoupe"
  cp -f "$ROM_DIR"/*.z5 "$ROMPATH/samcoupe/" || die "no ROMs at $ROM_DIR (spine stages them)"
fi

fetch_pinned "$SAMDOS_URL" "$SAMDOS_SHA256" "$STAGE_DIR/$SAMDOS_FILE"
fetch_pinned "$FIVE_URL" "$FIVE_SHA256" "$STAGE_DIR/$FIVE_FILE"
fetch_pinned "$SEC_URL" "$SEC_SHA256" "$STAGE_DIR/$SEC_FILE"
(cd "$STAGE_DIR" && sha256sum -- *.dsk *.sad *.mgt 2>/dev/null >MANIFEST.sha256) || true

# ---------------------------------------------------------------- compose ---
# samdos2 MUST be the first directory entry: the SAM ROM's BOOT loads whatever
# the first file is. `auto` is added afterwards, by the emulator.
log "composing the disk (mgtfs.py)"
PYTHONPATH="$HERE/../lib" python3 - "$STAGE_DIR" "$WORK/hive-nomenu.mgt" <<'PYEOF'
import sys
import mgtfs

stage, out = sys.argv[1], sys.argv[2]
dos = mgtfs.load(stage + "/SAMDOSVersion2.0.dsk")
five = mgtfs.load(stage + "/5in1_ManicMiner_Splat_MrPac_SnakeMania_Craft.sad")
sec = mgtfs.load(stage + "/TheSecretary.dsk")

# (source, filename) in the order they land on the disk. The DOS is first
# because BOOT loads the first entry; after that, order is cosmetic.
PLAN = [
    (dos, "samdos2"),                                        # SAMDOS 2.0
    (five, "MANIC M"), (five, "bank0"), (five, "bank1"),     # Manic Miner
    (five, "M SCREEN"),
    (five, "MR PAC"), (five, "MR PAC 1"),                    # Mr. Pac
    (five, "SPLATRUN"), (five, "ALLCODE"), (five, "LOADSCRN"),  # Splat!
    # The Secretary. Its two manuals (E_Manual 112, Sec_Man 106 sectors) are
    # left off -- they are the only things that do not fit, and a visitor at
    # the exhibit is not going to read a disk-based manual.
    # "Auto.Sec" is renamed twice over: SAMDOS boots the first auto* file it
    # finds, so left alone The Secretary's launcher steals the boot from our
    # menu -- and the new name must carry no ".", because MAME's natural
    # keyboard has no period mapping on this driver and emu.keypost stalls
    # mid-string on one (the menu's line 120 froze at LOAD "SE until this).
    (sec, "MDOS22"), (sec, "Auto.Sec", "SECRUN"), (sec, "Secretary"),
    (sec, "Chr1.Sec"), (sec, "Chr2.Sec"), (sec, "prn"), (sec, "code1"),
    (sec, "Menu$.Sec"), (sec, "pr-codes"), (sec, "Rkey$.Sec"),
    (sec, "po1.Sec"), (sec, "po2.Sec"), (sec, "code2"), (sec, "Dkeys.Key"),
    (sec, "Help.Sec"), (sec, "Ins.Sec"), (sec, "M-Data.Sec"), (sec, "cid.Key"),
]

comp = mgtfs.Composer()
for row in PLAN:
    img, name = row[0], row[1]
    entry = mgtfs.find(img, name)
    comp.add(entry, mgtfs.read_file(img, entry), name=row[2] if len(row) > 2 else None)
comp.write(out)
for name, kind, sectors in comp.names:
    print("    %-12s %-8s %4d sectors" % (name, kind, sectors), file=sys.stderr)
print("    %d of %d data sectors free" % (comp.free_sectors, mgtfs.DATA_SECTORS),
      file=sys.stderr)
PYEOF

# ------------------------------------------------------- the `auto` menu ---
MENU_SRC="$HERE/samcoupe/auto.bas"
[[ -f "$MENU_SRC" ]] || MENU_SRC="$HERE/../assets/samcoupe/auto.bas"
[[ -f "$MENU_SRC" ]] || die "menu source missing: $MENU_SRC"

log "generating the paced-typing Lua script"
python3 - "$MENU_SRC" "$WORK/type-menu.lua" <<'PYEOF'
import sys

src, out = sys.argv[1], sys.argv[2]
lines = [l.rstrip("\n") for l in open(src) if l.strip()]
lines.append('SAVE "auto" LINE 1')


def lua(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


body = ["-- generated by scripts/build-guests/tiles/samcoupe.sh -- do not hand-edit",
        "local lines = {"]
body += ['  "%s",' % lua(l) for l in lines]
body += [
    "}",
    "",
    "local function snap() manager.machine.video:snapshot() end",
    "",
    "emu.wait(6)",
    'emu.keypost("\\n")   -- the MGT boot screen EATS one key; without this,',
    "emu.wait(2)          -- BOOT arrives as OOT and SAVE goes to TAPE",
    'emu.keypost("BOOT\\n")',
    "emu.wait(12)",
    'emu.keypost("MODE 3\\n")  -- 85 columns: at the boot mode\'s 32, the menu',
    "emu.wait(3)             -- listing wraps, fills the screen and the editor",
    "                        -- stops accepting keys partway through line 120",
    "snap()",
    "for _, line in ipairs(lines) do",
    "  emu.keypost(line .. \"\\n\")",
    "  emu.wait(6)        -- SAM BASIC's editor cannot take a whole program at once",
    "end",
    "emu.wait(10)",
    "snap()",
]
open(out, "w").write("\n".join(body) + "\n")
PYEOF

# MAME wants the ROMs one level up from the samcoupe/ set directory, and a
# headless run needs SDL pointed at its dummy drivers -- there is no X here.
run_mame() { # run_mame <image> <lua> <emulated seconds>
  local cmd="cd $WORK && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy $MAME samcoupe"
  cmd+=" -rompath $ROMPATH -homepath . -cfg_directory ./cfg -nvram_directory ./nvram"
  cmd+=" -inipath . -snapshot_directory ./snap -skip_gameinfo -sound none"
  cmd+=" -video soft -window -flop1 $1 -autoboot_delay 1 -autoboot_script $2"
  cmd+=" -nothrottle -seconds_to_run $3"
  if [[ "$REMOTE" == 1 ]]; then
    # MAME runs as root over the door; hand the files back so the next local
    # rm/cp does not trip over root-owned snapshots.
    ssh lab "$cmd; chown -R 1000:1000 $WORK" >/dev/null 2>&1
  else
    bash -c "$cmd" >/dev/null 2>&1
  fi
}

log "typing the menu into the guest and SAVEing it (this is a real ~300s emulated run)"
rm -rf "$WORK/snap"
cp -f "$WORK/hive-nomenu.mgt" "$WORK/hive.mgt"
run_mame hive.mgt type-menu.lua 500 || die "MAME menu-entry run failed"

PYTHONPATH="$HERE/../lib" python3 -c "
import sys, mgtfs
img = mgtfs.load('$WORK/hive.mgt')
names = [e.name for e in mgtfs.read_dir(img)]
if 'auto' not in names:
    sys.exit('auto was never written to the disk; on it: %s' % names)
print('auto is on the disk (%d files)' % len(names))
" || die "the menu did not land on the disk"

# ------------------------------------------------------------- boot gate ---
if [[ "$GATE" == 1 ]]; then
  log "boot gate: cold-booting the composed disk and checking the frame"
  mkdir -p "$WORK/proof"
  cat >"$WORK/boot-gate.lua" <<'LUAEOF'
local function snap() manager.machine.video:snapshot() end
emu.wait(6)
emu.keypost("\n")   -- the boot screen eats one key
emu.wait(2)
emu.keypost("BOOT\n")
emu.wait(14)
snap()
LUAEOF
  rm -rf "$WORK/snap"
  cp -f "$WORK/hive.mgt" "$WORK/gate.mgt"
  run_mame gate.mgt boot-gate.lua 26 || die "boot gate: MAME run failed"
  GATE_PNG="$WORK/snap/samcoupe/0000.png"
  [[ -f "$GATE_PNG" ]] || die "boot gate: MAME wrote no frame"
  python3 - "$GATE_PNG" <<'PYEOF' || die "boot gate: the menu frame is blank"
import sys
import zlib

# Decode the PNG without a dependency: MAME writes 8-bit RGB, no interlace.
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
print("[build:samcoupe] gate frame %dx%d, %d/%d sampled bytes lit"
      % (w, h, lit, len(raw) // 64 + 1), file=sys.stderr)
sys.exit(0 if lit > 20 else 1)
PYEOF
  cp -f "$GATE_PNG" "$WORK/proof/01-menu-cold-boot.png"
  log "boot gate passed -- $WORK/proof/01-menu-cold-boot.png"
fi

# --------------------------------------------------------------- install ---
mkdir -p "$INSTALL_DIR"
cp -f "$WORK/hive.mgt" "$INSTALL_DIR/hive.mgt"
log "installed $INSTALL_DIR/hive.mgt ($(stat -c %s "$INSTALL_DIR/hive.mgt") bytes, sha256 $(sha256sum "$INSTALL_DIR/hive.mgt" | awk '{print $1}'))"
