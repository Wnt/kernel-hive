#!/bin/bash
# =============================================================================
# tiles/vision.sh — stage the `vision` station: VisiCorp Visi On 1.0 (1983) on
# an IBM 5160 XT (8088, 640 KB, CGA, 10 MB XT fixed disk, Mouse Systems serial
# mouse on COM1). docs/lab/VISION-WAVE.md is the wave; docs/guests/vision.md
# the operating manual.
#
# Stages, in order:
#   --fetch    fetch every input from its ORIGIN into $STAGE (URL + sha256 +
#              byte size pinned below; nothing is ever copied from the Virtual
#              OS Museum, which was reference only) — idempotent, hash-gated
#   --unpack   unpack the archives into $MEDIA (raw 360K PC-DOS images, the
#              TransCopy .TC Visi On disks, the PCE XT ROMs + hd0.pbi)
#   --compose  build the station disk set for the WINNING emulator route
#              (see the race verdict in docs/lab/VISION-WAVE.md §Race):
#              convert the TransCopy key disk with PCE's `psi` (the copy
#              protection lives on the flux; a plain-sector export loses it),
#              install Visi On once (A:VINSTALL, disk swap) and freeze the
#              result as the golden disk pair
#   (default)  all three
#
# Never commits media: the gallery is private, the repo is public (rule 1 —
# only URLs and hashes live here).
# =============================================================================
set -euo pipefail

OS_ID=vision
STAGE="${STAGE:-/data/assets-staging/$OS_ID}"
MEDIA="${MEDIA:-/data/vms/streamhost/assets/$OS_ID/media}"
UA="Mozilla/5.0 (X11; Linux x86_64) kernel-hive-lab/1.0"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

# name  size  sha256  origin URL — measured 2026-09-13 (stat -c %s, sha256sum)
# Visi On disks: WinWorld "Visi On 1.0" (https://winworldpc.com/product/visi-on/1x),
# each 7z = one title's disk pair as Kryoflux raw + SuperCard Pro .scp + TransCopy .TC.
# PC-DOS 2.00: WinWorld (https://winworldpc.com/product/pc-dos/2x).
# PCE (GPL, hampa.ch): the 2025-04-20 git snapshot — the 2014 snapshot the VOM used
# has rotated out of hampa.ch's /pub/pce/pre/ (oldest kept is 2021-08).
# MAME ibm5160 ROM set: archive.org mame-0.264-roms-non-merged.
SOURCES=(
  "VOAPP-1.0.7z 32863268 873b87d3d5fb068beaf4e9ef76e5ff65c5ddae41f2d09eb816398fae677c80f7 https://winworldpc.com/download/3910ba20-b30e-11ea-8b3c-fa163e9022f0"
  "VOCALC-1.0.7z 15907010 60c96a695047f039a8f18ada33cb8ac2e243b037d2fb8c7bf60737bf9f572da3 https://winworldpc.com/download/1f290193-b32c-11ea-8b14-fa163e9022f0"
  "VOGRAPH-1.0.7z 15232234 b50fd08377dd0afe26b82ed19961811cac2b712a98a8674482f6009310d2e4b4 https://winworldpc.com/download/8c90fc3a-b32c-11ea-8b14-fa163e9022f0"
  "VOWORD-1.0.7z 16210938 3f1bacde70437ba5f7d77596f03009dabdf4c744603e1ca8a5da75fd96388079 https://winworldpc.com/download/4c5dd471-b32d-11ea-8b14-fa163e9022f0"
  "IBM-PCDOS-2.00-5.25.7z 3382112 b47dff3322cd926e149521d5ce4d1e9246e0fc18291f1e8fc5d675ade8f9e351 https://winworldpc.com/download/e280a6c3-99c2-a1c5-bdc2-b4e280a011ef"
  "pce-20250420-cc0c583c.tar.gz 1113043 32a37f01bb9cabaa9cc5b5e0f72268755f3211430c57f83871da67c5aedd7117 http://www.hampa.ch/pub/pce/pre/pce-20250420-cc0c583c/pce-20250420-cc0c583c.tar.gz"
  "pce-20250420-cc0c583c-ibm-xt-pcdos-2.00.zip 1405591 0f6a14b92c158c1cdf774818f1afed34de4404c84ee4470cee8def1cb532eec5 http://www.hampa.ch/pub/pce/pre/pce-20250420-cc0c583c/machines/pce-20250420-cc0c583c-ibm-xt-pcdos-2.00.zip"
  "ibm5160.zip 145947 57f75c9dc87bed4b33cb9001b628774c1fcf1113bd4a0f650222709af82a2783 https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29/ibm5160.zip"
  "isa_hdc.zip 5558 a732c67b3716b3eb92bf401904ebfcad3a0b826f7f118f6c2c0a966729900639 https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29/isa_hdc.zip"
)

verify() { # verify <file> <size> <sha256>
  [ -f "$1" ] || return 1
  [ "$(stat -c %s "$1")" = "$2" ] || return 1
  [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$3" ]
}

do_fetch() {
  mkdir -p "$STAGE"
  local row name size sha url
  for row in "${SOURCES[@]}"; do
    read -r name size sha url <<<"$row"
    if verify "$STAGE/$name" "$size" "$sha"; then
      log "ok       $name ($size bytes)"
      continue
    fi
    log "fetching $name from $url"
    curl -fsSL -A "$UA" -o "$STAGE/$name.part" "$url"
    mv "$STAGE/$name.part" "$STAGE/$name"
    verify "$STAGE/$name" "$size" "$sha" || die "$name: size/sha256 mismatch after fetch (expected $size / $sha)"
  done
  (cd "$STAGE" && sha256sum "${SOURCES[@]%% *}" >MANIFEST.sha256)
  log "staged at $STAGE (MANIFEST.sha256 written)"
}

do_unpack() {
  local row name size sha url
  for row in "${SOURCES[@]}"; do
    read -r name size sha url <<<"$row"
    verify "$STAGE/$name" "$size" "$sha" || die "$name missing or wrong in $STAGE — run --fetch"
  done
  mkdir -p "$MEDIA/tc" "$MEDIA/pcdos" "$MEDIA/pce" "$MEDIA/roms"
  # the four Visi On titles: only the TransCopy members (the .scp flux dumps are
  # the same disks in a format neither emulator reads; they stay in the archive)
  local a
  for a in VOAPP VOCALC VOGRAPH VOWORD; do
    7z e -y -o"$MEDIA/tc" "$STAGE/$a-1.0.7z" '*/Transcopy/*.TC' >/dev/null
  done
  7z e -y -o"$MEDIA/pcdos" "$STAGE/IBM-PCDOS-2.00-5.25.7z" '*/Disk0?.img' >/dev/null
  unzip -qo "$STAGE/pce-20250420-cc0c583c-ibm-xt-pcdos-2.00.zip" 'rom/*' hd0.pbi pce-5160.cfg -d "$MEDIA/pce"
  unzip -qo "$STAGE/ibm5160.zip" -d "$MEDIA/roms"
  unzip -qo "$STAGE/isa_hdc.zip" -d "$MEDIA/roms"
  # measured 2026-09-13: every .TC is 1114112 bytes, every PC-DOS image 184320
  local f
  for f in "$MEDIA"/tc/*.TC; do [ "$(stat -c %s "$f")" = 1114112 ] || die "$f: not a 1114112-byte TransCopy image"; done
  for f in "$MEDIA"/pcdos/Disk0?.img; do [ "$(stat -c %s "$f")" = 184320 ] || die "$f: not a 360K image"; done
  log "unpacked: $(find "$MEDIA/tc" -name '*.TC' | wc -l) TransCopy disks, $(find "$MEDIA/pcdos" -name '*.img' | wc -l) PC-DOS images, PCE ROMs + hd0.pbi, MAME roms"
}

do_compose() {
  # Filled in from the race verdict (docs/lab/VISION-WAVE.md §Race) — the
  # emulator-specific disk composition. Until then the smoke rig under
  # /data/vms/sandbox/vision/race/<theory>/ is the reference.
  die "--compose: pending the race verdict (docs/lab/VISION-WAVE.md §Race)"
}

case "${1:-all}" in
  --fetch) do_fetch ;;
  --unpack) do_unpack ;;
  --compose) do_compose ;;
  all)
    do_fetch
    do_unpack
    do_compose
    ;;
  *) die "usage: $0 [--fetch|--unpack|--compose]" ;;
esac
