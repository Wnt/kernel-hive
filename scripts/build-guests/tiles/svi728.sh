#!/bin/bash
# Fetch the International SVI-728 BIOS; native MAME is built separately.
set -euo pipefail
STAGING=/data/assets-staging/svi728/roms
mkdir -p "$STAGING"
URL='https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29/svi728.zip'
SHA=caa87ceeb46257de910e7ca66b16a352d6e43cad8a849af7890b8328ea460eea
if [ ! -f "$STAGING/svi728.zip" ]; then
  curl -fL --retry 3 -A 'Mozilla/5.0' "$URL" -o "$STAGING/svi728.zip"
fi
printf '%s  %s\n' "$SHA" "$STAGING/svi728.zip" | sha256sum -c -
unzip -oq "$STAGING/svi728.zip" -d "$STAGING"
echo 'SVI-728 International ROM staged; build-mame-native.sh svi728 builds the emulator.'
