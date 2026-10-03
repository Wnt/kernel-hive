#!/bin/bash
# Hash-pinned offline Spectravideo assets. ROMs/media stay outside Git.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING="${SVI_STAGING:-/data/assets-staging/svi328}"
ASSETS="${SVI_ASSETS:-/data/vms/streamhost/assets/svi328}"
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
echo "svi328: media verified; build-mame-native.sh svi328 builds the cached native emulator."
