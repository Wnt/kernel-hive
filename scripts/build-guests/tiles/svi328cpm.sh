#!/bin/bash
# Hash-pinned offline Spectravideo assets. ROMs/media stay outside Git.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING="${SVI_STAGING:-/data/assets-staging/svi328cpm}"
ASSETS="${SVI_ASSETS:-/data/vms/streamhost/assets/svi328cpm}"
mkdir -p "$STAGING/roms" "$ASSETS/media"
fetch() {
  local dest="$1" url="$2" sha="$3"
  if [ ! -f "$dest" ] || [ "$(sha256sum "$dest" | cut -d' ' -f1)" != "$sha" ]; then
    curl --fail --location --retry 3 --output "$dest.tmp" "$url"
    mv "$dest.tmp" "$dest"
  fi
  echo "$sha  $dest" | sha256sum --check --status
}
fetch "$STAGING/svi328.zip" \
  'https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29/svi328.zip' \
  c04e51b23da6b13f30541f5fe8cdf45e79b114350c2b5e541efa54921308378e
unzip -oq "$STAGING/svi328.zip" -d "$STAGING/roms"
fetch "$STAGING/sv806.zip" 'https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29/sv806.zip' 73aeb55e8dc1e39580db3177598a2ec6f129969eb1af5be88cc7a16f22493bfa
unzip -oq "$STAGING/sv806.zip" -d "$STAGING/roms"
fetch "$STAGING/cpm224dd.zip" 'https://archive.org/download/MAME_0.228_Software_List_ROMs_merged/MAME_0.228_Software_List_ROMs_merged.zip/svi318_flop%2Fcpm224dd.zip' 7a6cc43d8e204d3ac3163db3d083650a5e55b8a2a7aba81b591776d6f90f2d29
fetch "$STAGING/MBASIC.COM" 'http://www.retroarchive.org/cpm/lang/Mbasic.com' 29d957fc6899c24f6296a1662a27eca545d85ee3f7d70d2794c9d045d92ff157
unzip -oq "$STAGING/cpm224dd.zip" -d "$STAGING"
python3 "$HERE/../lib/svi_cpm_media.py" "$STAGING/cpm224dd.imd" "$STAGING/MBASIC.COM" "$ASSETS/media/hive-cpm.dsk"
chmod 444 "$ASSETS/media/hive-cpm.dsk"
echo "svi328cpm: media verified; build-mame-native.sh svi328cpm builds the cached native emulator."
