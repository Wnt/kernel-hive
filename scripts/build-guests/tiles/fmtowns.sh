#!/bin/bash
# =============================================================================
# tiles/fmtowns.sh — media plane for the fmtowns station (Fujitsu FM TOWNS,
# Towns OS V2.1 L51). Owned by the fmtowns wave (docs/lab/FMTOWNS-WAVE.md).
#
# WHAT IT MAKES
#   $INSTALL_DIR/townsos-v21l51.chd   the Towns System Software V2.1 L51 CD
#                                      (the BOOT VOLUME — the Towns boots from
#                                      CD into TownsMENU, nothing is installed)
#   $ROM_STAGE/FMT_*.ROM               the five Fujitsu system ROMs, hash-gated,
#                                      which native.d/fmtowns.sh's stage-romset
#                                      step matches to MAME's romset by sha1
#
# Everything is fetched by URL + sha256 (the gallery is private, so the bits
# stay under /data and are never committed — only URL, size and hash live in
# the repo). The Virtual OS Museum runs this OS on Tsugaru, which is where the
# FACT that the System Software CD boots straight into TownsMENU comes from;
# nothing of theirs is copied.
#
# The emulator plane (the MAME binary + rompath + boot gate) is
# scripts/build-guests/emulators/build-mame-native.sh fmtowns; run this first,
# then that. The CHD is composed with chdman (labhost has /usr/bin/chdman; CT950
# does not, so chdman runs through the one door, AGENTS.md rule 2).
#
# Usage: fmtowns.sh [--no-gate]
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_ID="fmtowns"

STAGE_DIR="${STAGE_DIR:-/data/assets-staging/$OS_ID}"
ROM_STAGE="${ROM_STAGE:-$STAGE_DIR/roms}"
CD_STAGE="${CD_STAGE:-$STAGE_DIR/cd}"
INSTALL_DIR="${INSTALL_DIR:-/data/vms/streamhost/assets/$OS_ID/media}"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
GATE=1
[[ "${1:-}" == "--no-gate" ]] && GATE=0

# ---- sources: URL + sha256 + byte size (measured, ledger facts) --------------
# The five Fujitsu system ROMs, as the MAME 0.272 merged romset's mess/fmtowns.7z
# (archive.org item mame-0.272-romset-complete-merged). Only the five canonical
# files are used; the archive's regional variants (fmt_*_a.rom, mytowns*.rom
# boot-select bytes) are left alone. MEASURED 2026-09-13.
ROMS_URL="https://archive.org/download/mame-0.272-romset-complete-merged/mess/fmtowns.7z"
ROMS_SHA256="5856826ef6475ebdf383982d47219bc6b3890cb6071d456ae6d3079c4e5081ac" # 967043 bytes
ROMS_ARCHIVE="fmtowns.7z"
# name:sha256 — FMT_SYS is the Model 1/2 system ROM (MAME base `fmtowns` set,
# sha1 15d9cc70), the other four are the Towns II generation's (sha1
# 7564020d / 57fd1464 / 1920711c / a216482e). No single MAME machine matches
# all five by hash — see native.d/fmtowns.sh for how the rompath is assembled
# and docs/lab/FMTOWNS-WAVE.md for the measured sha1 table.
ROM_FILES=(
  "FMT_SYS.ROM:7d4e89355e3575ae062516ece72f56160cd91f54e9bff74f9c438c883a2f7b9a" # 262144
  "FMT_DOS.ROM:b760d991c087c25a7e18e52f1af4bfd601f6abe8f4ebadac51f34742374cf17f" # 524288
  "FMT_F20.ROM:dca1f314ae2f5dc937706624990b8521016ee2231558f6cbe169bbc305efb774" # 524288
  "FMT_DIC.ROM:fdec9c3b4be58426623b3266bc6f246673134c427c8683332c24381f522ecdc7" # 524288
  "FMT_FNT.ROM:aa9e9565d3047c51ee418712be8daa391b0d8f21f92fc02e4616e3523ca50b9d" # 262144
)
# Towns System Software V2.1 L51 (Fujitsu, 1995) — the bootable CD. archive.org
# item neo_kobe_fujitsu_fm_towns_2016-02-25-repack_20200803, path "Fujitsu FM
# Towns/[OS] Towns System Software v2.1 L51 (Fujitsu)/[OS] Towns System Software
# v2.1 L51 [CD].7z". The archive is CloneCD (.ccd/.img/.sub) plus a .cue whose
# FILE line names the bracketed original; the builder writes its own .cue
# (below) against the renamed image. MEASURED 2026-09-13.
CD_URL="https://archive.org/download/neo_kobe_fujitsu_fm_towns_2016-02-25-repack_20200803/Fujitsu%20FM%20Towns/%5BOS%5D%20Towns%20System%20Software%20v2.1%20L51%20%28Fujitsu%29/%5BOS%5D%20Towns%20System%20Software%20v2.1%20L51%20%5BCD%5D.7z"
CD_SHA256="43db0465910658d515425c0f314d7b5013ee52d0c24e0791f7e84636c0648b85" # 252788766 bytes
CD_ARCHIVE="towns-sysv21-l51-cd.7z"
CD_IMG_SHA256="5adbae1b5e32cf9ed285f07b9ad94701f18cdc6d483fbb3ba47b5cd0dd50f8ab" # 593767104 bytes, MODE1/2352 + 8 audio tracks
CD_IMG="towns-sysv21-l51-cd.img"
CD_CUE="towns-sysv21-l51-cd.cue"
# The composed CHD's sha256; empty = not yet pinned (pin it from the first
# compose, then a chdman version drift shows up here instead of on the glass).
CHD_SHA256="${CHD_SHA256:-}"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}
door() { ssh lab "$@"; } # the one door; /data is the same mount on both sides

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

mkdir -p "$ROM_STAGE" "$CD_STAGE" "$WORK"
fetch_pinned "$ROMS_URL" "$ROMS_SHA256" "$ROM_STAGE/$ROMS_ARCHIVE"
fetch_pinned "$CD_URL" "$CD_SHA256" "$CD_STAGE/$CD_ARCHIVE"

# ---- ROMs: the five Fujitsu files, each hash-gated ----------------------------
log "unpacking the ROM archive"
(cd "$ROM_STAGE" && 7z x -y -o. "$ROMS_ARCHIVE" >/dev/null) || die "7z failed on $ROMS_ARCHIVE"
for spec in "${ROM_FILES[@]}"; do
  name="${spec%%:*}" sha="${spec#*:}"
  f="$(find "$ROM_STAGE" -iname "$name" -type f | head -1)"
  [[ -n "$f" ]] || die "ROM $name not in $ROMS_ARCHIVE"
  got="$(sha256sum "$f" | awk '{print $1}')"
  [[ "$got" == "$sha" ]] || die "ROM $name sha256 $got != $sha"
  [[ "$f" == "$ROM_STAGE/$name" ]] || cp -f "$f" "$ROM_STAGE/$name"
  log "ROM $name $(stat -c %s "$ROM_STAGE/$name") bytes OK"
done

# ---- the CD: CloneCD image → our own cue → CHD -------------------------------
log "unpacking the CD archive"
(cd "$CD_STAGE" && 7z x -y -o. "$CD_ARCHIVE" >/dev/null) || die "7z failed on $CD_ARCHIVE"
IMG="$CD_STAGE/$CD_IMG"
if [[ ! -f "$IMG" ]]; then
  src="$(find "$CD_STAGE" -iname '*.img' -type f | head -1)"
  [[ -n "$src" ]] || die "no .img in $CD_ARCHIVE"
  mv -f "$src" "$IMG"
fi
[[ "$(sha256sum "$IMG" | awk '{print $1}')" == "$CD_IMG_SHA256" ]] || die "CD image sha256 mismatch: $IMG"
log "CD image $(stat -c %s "$IMG") bytes OK"
CUE="$CD_STAGE/$CD_CUE"
cat >"$CUE" <<CUEEOF
FILE "$CD_IMG" BINARY
   TRACK 1 MODE1/2352
   INDEX 1 00:00:00
   TRACK 2 AUDIO
   INDEX 1 40:00:00
   TRACK 3 AUDIO
   INDEX 1 41:00:00
   TRACK 4 AUDIO
   INDEX 1 42:01:30
   TRACK 5 AUDIO
   INDEX 1 43:05:27
   TRACK 6 AUDIO
   INDEX 1 44:08:67
   TRACK 7 AUDIO
   INDEX 1 53:04:22
   TRACK 8 AUDIO
   INDEX 1 54:11:22
   TRACK 9 AUDIO
   INDEX 1 55:02:32
CUEEOF
mkdir -p "$INSTALL_DIR"
CHD="$INSTALL_DIR/townsos-v21l51.chd"
if [[ -f "$CHD" ]] && { [[ -z "$CHD_SHA256" ]] || [[ "$(sha256sum "$CHD" | awk '{print $1}')" == "$CHD_SHA256" ]]; }; then
  log "CHD already composed, sha256 matches"
else
  log "chdman createcd (through the door: chdman lives on labhost)"
  door "chdman createcd -f -i '$CUE' -o '$CHD.part' >/dev/null && mv -f '$CHD.part' '$CHD'" || die "chdman failed"
  got="$(sha256sum "$CHD" | awk '{print $1}')"
  [[ -z "$CHD_SHA256" || "$got" == "$CHD_SHA256" ]] || die "composed CHD sha256 $got != pinned $CHD_SHA256 (chdman version drift? re-pin deliberately)"
fi
log "CHD $CHD $(stat -c %s "$CHD") bytes"
(cd "$STAGE_DIR" && sha256sum roms/FMT_*.ROM cd/$CD_IMG cd/$CD_CUE >MANIFEST.sha256) || true

# ---- gate: the emulator plane's boot gate is the framebuffer proof ----------
if [[ "$GATE" == 1 ]]; then
  log "boot gate: build-mame-native.sh fmtowns (drawshm frame floor, through the fleet builder)"
  door "cd $(cd "$HERE/../../.." && pwd) && JOBS=\${JOBS:-4} nice -n 10 scripts/build-guests/emulators/build-mame-native.sh fmtowns" ||
    die "build-mame-native.sh fmtowns failed (its gate is the framebuffer proof)"
fi
log "done: $CHD + $ROM_STAGE/FMT_*.ROM"
