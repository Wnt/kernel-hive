#!/bin/bash
# Source original FS-A1GT media, verify archival hashes, stage sandbox assets.
set -euo pipefail
STAGING="${MSXTURBOR_STAGING:-/data/vms/sandbox/msxturbor/media}"
DEST="${MSXTURBOR_ASSETS:-/data/vms/sandbox/msxturbor/assets}"
mkdir -p "$STAGING" "$DEST/media"
fetch() {
  local name="$1" url="$2" hash="$3"
  if [[ ! -s "$STAGING/$name" ]]; then
    curl -fL -A 'Mozilla/5.0' "$url" -o "$STAGING/$name.tmp"
    mv "$STAGING/$name.tmp" "$STAGING/$name"
  fi
  printf '%s  %s\n' "$hash" "$STAGING/$name" | sha256sum --check --status
}
fetch fsa1gt.zip \
  'https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29/fsa1gt.zip' \
  6de5277d16af829a60520d1a2c79005626fa53ec805d1d3f9987cbbe1df5493f
hashes=(
  955f5d68006e77f7e47301ceddd6954203c5003c3b55386ed9d3a0d90d870553
  4e09ff55b282d3cd93fd4dba07ad85c0ac4694ca914136a54b83f5b97bf9d423
  a975191c53b670d111b59e5066f1895e5c14f2e80f330cca7df64ca520de6e31
)
for n in 1 2 3; do
  fetch "disk$n.zip" \
    "https://download.file-hunter.com/System%20Disks/Computers/Panasonic/FSA1GT/FSA1GT%20System%20Disk%20$n.zip" \
    "${hashes[n - 1]}"
  unzip -p "$STAGING/disk$n.zip" "FSA1GT System Disk $n.dsk" >"$DEST/media/disk$n.dsk"
done
unzip -p "$STAGING/fsa1gt.zip" a1gtfirm.rom >"$DEST/media/fs-a1gt_firmware.rom"
unzip -p "$STAGING/fsa1gt.zip" a1gtkfn.rom >"$DEST/media/fs-a1gt_kanjifont.rom"
(
  cd "$DEST/media"
  sha256sum --check <<'HASHES'
b835503c18b90ee7ddd29f6093ce2e4987da808075451a41bd92af5ff7d71709  disk1.dsk
cfcd8ba8e700fce9cac90a137c4bb4d64e8241856e1ca09d929ead3d603a10a0  disk2.dsk
33990ef3ba0fab0bfcb65aa918b8af6c9e63325cedce4934e35ff41912977dfa  disk3.dsk
7eeacb763c39de7185b1ab8bbf9c625f1c5717444e20ea03d3ee2172dfeefe9f  fs-a1gt_firmware.rom
d87ce758a7171870a2a3e7893e09cbba2bd68ee70b4d0f0e49dd2ecd60aafdd1  fs-a1gt_kanjifont.rom
HASHES
)
chmod a-w "$DEST/media/"*
