#!/bin/bash
# Build the apple2e station's ProDOS hard-disk volume (hive.hdv): a 32 MB
# ProDOS-order raw-block image bootable behind MAME's cffa2 card (-hard1),
# carrying a one-keypress Applesoft STARTUP menu — the Apple II equivalent of
# the FreeDOS station's MENU.BAT (scripts/build-guests/tiles/freedos.sh).
#
# Owned by the apple2e wave's "media" stream (docs/lab/APPLE2E-WAVE.md). This
# script does NOT touch the emulator/ROM plane (native stream) or the SPA
# (spa stream) — it only fetches media, composes the volume with a2kit, and
# installs it to the streamhost asset dir the "native" stream's builder reads.
#
# ProDOS 2.4.2 (John Brooks) was picked over Apple's 2.0.3 because it already
# carries BASIC.SYSTEM (the program ProDOS auto-boots into, and which in turn
# auto-runs a root-level Applesoft program named STARTUP -- the Apple II's
# AUTOEXEC.BAT). AppleWorks 3.0 (Claris, 1989) is shipped from the single
# "AppleWorks30.2mg" mirror image, which already carries every file the
# 80-column suite needs (APLWORKS.SYSTEM + all thirteen SEG.* / dictionary
# files) in one place -- cleaner than reassembling the six-disk retail set.
# Dazzle Draw 1.2 (Broderbund, 1988) is an ordinary ProDOS volume with a
# DD.SYSTEM launcher plus a DD.OBJ support directory, so it installs the same
# way AppleWorks does: PREFIX to its directory, then "-DD.SYSTEM".
#
# Angry Birds (8-Bit Shack's free Apple //e port, double lo-res) is NOT on the
# volume yet: 8bitshack.org/post/angrybirds now serves the site's own 404
# page, and the free-Christmas-download mirror named in a still-indexed
# secondary source (callapple.org) -- www.golombeck.eu/fileadmin/downloads/
# AngryBirds_V101.dsk -- refuses our TLS SNI / returns 503. The menu therefore
# does not MENTION it: STARTUP.bas carries a @BIRDS@ token this script
# substitutes with 1 or 0, and at 0 the [3] line, the [3] key and the "3" in
# the prompt all disappear -- a visitor never reads "(not staged yet)" on the
# exhibit. Set ANGRYBIRDS_DSK_URL / ANGRYBIRDS_DSK_SHA256 and re-run to bring
# the entry back; see docs/lab/APPLE2E-WAVE.md for the open item.
#
# Usage: apple2e.sh [--force]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_ID="apple2e"

A2KIT="${A2KIT:-/data/vms/sandbox/apple2e/tools/a2kit}"
STAGE_DIR="${STAGE_DIR:-/data/assets-staging/apple2e/media}"
INSTALL_DIR="${INSTALL_DIR:-/data/vms/streamhost/assets/apple2e/media}"
WORK="${WORK:-/data/vms/build-${OS_ID}-media}"

MIRROR_BASE="https://mirrors.apple2.org.za/ftp.apple.asimov.net/images"

# name  url  sha256
PRODOS_URL="$MIRROR_BASE/masters/prodos/ProDOS_2_4_2.dsk"
PRODOS_SHA256="d1e6fab8d9a25acf6e10ffa15e4120a616898c03613ab87a8e12882b12102543"

APPLEWORKS_URL="$MIRROR_BASE/productivity/integrated/appleworks/v3.0/Appleworks30.2mg"
APPLEWORKS_SHA256="ea624d6b6fe6fb932fdd0de3035a4714cd3700e3fee7da8ac28b8540dc14b469"

DAZZLE_URL="$MIRROR_BASE/productivity/graphics/dazzle_draw/Dazzle%20Draw%20v1.2%20%28Broderbund-1988%29.dsk"
DAZZLE_SHA256="291f54945a1c946ba7985093ce686d01f5d74c7173cf84b0108c0839be0e6191"

# Not yet reachable -- see header note. Left blank on purpose; set both to
# resume the Angry Birds copy step once a working mirror exists.
ANGRYBIRDS_DSK_URL="${ANGRYBIRDS_DSK_URL:-}"
ANGRYBIRDS_DSK_SHA256="${ANGRYBIRDS_DSK_SHA256:-}"

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
    log "staged copy of $(basename "$dest") has wrong sha256 ($have) -- refetching"
    rm -f "$dest"
  fi
  log "fetching $(basename "$dest")"
  curl -fsSL -o "$dest.part" "$url" || die "fetch failed: $url"
  local got
  got="$(sha256sum "$dest.part" | awk '{print $1}')"
  [[ "$got" == "$sha" ]] || die "sha256 mismatch for $(basename "$dest"): got $got want $sha"
  mv "$dest.part" "$dest"
}

[[ -x "$A2KIT" ]] || die "a2kit not found/executable at $A2KIT"

mkdir -p "$STAGE_DIR" "$WORK"

fetch_pinned "$PRODOS_URL" "$PRODOS_SHA256" "$STAGE_DIR/ProDOS_2_4_2.dsk"
fetch_pinned "$APPLEWORKS_URL" "$APPLEWORKS_SHA256" "$STAGE_DIR/AppleWorks30.2mg"
fetch_pinned "$DAZZLE_URL" "$DAZZLE_SHA256" "$STAGE_DIR/dazzledraw_v12_broderbund_1988.dsk"
if [[ -n "$ANGRYBIRDS_DSK_URL" && -n "$ANGRYBIRDS_DSK_SHA256" ]]; then
  fetch_pinned "$ANGRYBIRDS_DSK_URL" "$ANGRYBIRDS_DSK_SHA256" "$STAGE_DIR/angrybirds.dsk"
fi

HDV="$WORK/hive.po"
rm -f "$HDV"
"$A2KIT" mkdsk -o prodos -t po -k hdmax -v HIVE -d "$HDV" ||
  die "mkdsk failed"

# ProDOS kernel + BASIC.SYSTEM (the program ProDOS boots by default, and which
# auto-runs a root file named STARTUP).
"$A2KIT" cp "$STAGE_DIR/ProDOS_2_4_2.dsk/PRODOS" "$HDV" || die "copy PRODOS failed"
"$A2KIT" cp "$STAGE_DIR/ProDOS_2_4_2.dsk/BASIC.SYSTEM" "$HDV" || die "copy BASIC.SYSTEM failed"

# AppleWorks 3.0 -- APLWORKS.SYSTEM + every SEG.* + the dictionary, all in /AW.
"$A2KIT" mkdir -f AW -d "$HDV" || die "mkdir /AW failed"
for f in APLWORKS.SYSTEM SEG.00 SEG.XM SEG.RM SEG.AM SEG.EL SEG.PR SEG.ER \
  SEG.AW SEG.WP SEG.DB SEG.SS MAIN.DICTIONARY; do
  "$A2KIT" cp "$STAGE_DIR/AppleWorks30.2mg/$f" "$HDV/AW" || die "copy AW/$f failed"
done

# Dazzle Draw 1.2 -- DD.SYSTEM + DD.OBJ (engine) + UTILITIES, all in /DAZZLE.
"$A2KIT" mkdir -f DAZZLE -d "$HDV" || die "mkdir /DAZZLE failed"
"$A2KIT" cp "$STAGE_DIR/dazzledraw_v12_broderbund_1988.dsk/DD.SYSTEM" "$HDV/DAZZLE" ||
  die "copy DD.SYSTEM failed"
"$A2KIT" mkdir -f DAZZLE/DD.OBJ -d "$HDV" || die "mkdir /DAZZLE/DD.OBJ failed"
for f in BOOT.4000 BOOT.4400 TITLEPAGE IRQ.ROUTINE INP.MODS FONTS \
  DZLDRW.MAIN DZLDRW.AUX CGR.RAMCARD AUX.RAMCARD FILESYSTEM; do
  "$A2KIT" cp "$STAGE_DIR/dazzledraw_v12_broderbund_1988.dsk/DD.OBJ/$f" "$HDV/DAZZLE/DD.OBJ" ||
    die "copy DD.OBJ/$f failed"
done
"$A2KIT" mkdir -f DAZZLE/UTILITIES -d "$HDV" || die "mkdir /DAZZLE/UTILITIES failed"
for f in HELP.INFO SLIDE1.SYSTEM SLIDE2.SYSTEM; do
  "$A2KIT" cp "$STAGE_DIR/dazzledraw_v12_broderbund_1988.dsk/UTILITIES/$f" "$HDV/DAZZLE/UTILITIES" ||
    die "copy UTILITIES/$f failed"
done

BIRDS=0
if [[ -f "$STAGE_DIR/angrybirds.dsk" ]]; then
  log "Angry Birds source present -- wiring /HIVE/BIRDS (adjust file list to the real image's catalog)"
  "$A2KIT" mkdir -f BIRDS -d "$HDV" || die "mkdir /BIRDS failed"
  # TODO: once a reachable source exists, `a2kit catalog -d angrybirds.dsk`
  # and copy its actual files here; STARTUP.bas's [3] branch assumes
  # /HIVE/BIRDS/ANGRY.BIRDS as a SYS launcher -- adjust both together.
  BIRDS=1
else
  log "Angry Birds not staged (see header) -- the menu omits [3] entirely"
fi

# STARTUP menu (Applesoft, tokenized, loads at $0801 / 2049 decimal).
# @BIRDS@ -> 1/0: the [3] line, the [3] key and the "3" in the prompt are all
# gated on that one variable, so an unstaged game is INVISIBLE to the visitor
# rather than advertised as missing.
STARTUP_SRC="$HERE/../assets/apple2e/STARTUP.bas"
[[ -f "$STARTUP_SRC" ]] || die "STARTUP.bas source missing: $STARTUP_SRC"
grep -q '@BIRDS@' "$STARTUP_SRC" || die "STARTUP.bas lost its @BIRDS@ token"
sed "s/@BIRDS@/$BIRDS/" "$STARTUP_SRC" >"$WORK/STARTUP.bas"
"$A2KIT" tokenize -a 2049 -t atxt <"$WORK/STARTUP.bas" >"$WORK/STARTUP.atok" ||
  die "tokenize STARTUP.bas failed"
"$A2KIT" put -f STARTUP -t atok -d "$HDV" <"$WORK/STARTUP.atok" ||
  die "put STARTUP failed"

# Plain-text copy of the menu, for anyone browsing the volume.
{
  cat <<'EOF'
APPLE //e -- PRODOS MENU
========================
[1] AppleWorks 3.0
[2] Dazzle Draw 1.2
EOF
  [[ "$BIRDS" == 1 ]] && echo "[3] Angry Birds"
  cat <<'EOF'
[B] BASIC prompt -- type RUN STARTUP to return

Reset always returns to this menu (STARTUP auto-runs under BASIC.SYSTEM).
EOF
} >"$WORK/MENU.README.txt"
"$A2KIT" put -f MENU.README -t txt -d "$HDV" <"$WORK/MENU.README.txt" ||
  die "put MENU.README failed"

log "composed volume catalog:"
"$A2KIT" catalog -d "$HDV" >&2

mkdir -p "$INSTALL_DIR"
cp -f "$HDV" "$INSTALL_DIR/hive.hdv"
log "installed $INSTALL_DIR/hive.hdv ($(stat -c %s "$INSTALL_DIR/hive.hdv") bytes, sha256 $(sha256sum "$INSTALL_DIR/hive.hdv" | awk '{print $1}'))"
