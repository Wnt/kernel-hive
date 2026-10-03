#!/bin/bash
# Prepare SVI-738 CP/M 2.28 release 2.1 with Microsoft BASIC and original demos.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING=/data/assets-staging/svi738
ASSETS=/data/vms/streamhost/assets/svi738
fetch() {
  local url="$1" file="$2" sha="$3"
  if [ ! -f "$file" ]; then
    curl -fL --retry 3 -A 'Mozilla/5.0' "$url" -o "$file"
  fi
  printf '%s  %s\n' "$sha" "$file" | sha256sum -c -
}
command -v dsktrans >/dev/null
mkdir -p "$STAGING/roms" "$STAGING/media" "$ASSETS/media"
fetch 'https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29/svi738sw.zip' \
  "$STAGING/roms/svi738sw.zip" 4955f7a7eb6630d35f477381ebdcfc30b717b1a7ab7e58619db9ed8f1d787345
unzip -oq "$STAGING/roms/svi738sw.zip" -d "$STAGING/roms"
fetch 'https://hansotten.file-hunter.com/uploads/files/svi738systemdisks.zip' \
  "$STAGING/media/system.zip" 07d28c56d7e98e24b3de4d2a3e7128133428321df6b1a88a7a0756e4123c7cd6
unzip -p "$STAGING/media/system.zip" SVICPM1.IMG >"$STAGING/media/SVICPM1.IMG"
# Auto-detection guesses 40x8 from a CP/M boot sector. Explicit 40x9 geometry
# plus last cylinder 79 reads the actual CopyQM 80x1x9 layout without padding.
dsktrans -itype copyqm -otype raw -format pcw180 -last 79 \
  "$STAGING/media/SVICPM1.IMG" "$STAGING/media/cpm360.dsk" >"$STAGING/media/convert.log" 2>&1
fetch 'http://www.retroarchive.org/cpm/lang/Mbasic.com' \
  "$STAGING/media/MBASIC.COM" 29d957fc6899c24f6296a1662a27eca545d85ee3f7d70d2794c9d045d92ff157
python3 "$HERE/../lib/svi738_disk.py" "$STAGING/media/cpm360.dsk" \
  "$STAGING/media/MBASIC.COM" "$ASSETS/media/hive-cpm.dsk"
printf '%s  %s\n' 5fa4b35a894410753ad2488e6bf044719ca6426d18750f9ec53a52cb2a2363ac \
  "$ASSETS/media/hive-cpm.dsk" | sha256sum -c -
chmod 444 "$ASSETS/media/hive-cpm.dsk"
echo 'SVI-738 CP/M fixture ready; build-mame-native.sh svi738 builds the emulator.'
