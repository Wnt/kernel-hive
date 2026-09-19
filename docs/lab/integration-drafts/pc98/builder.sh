#!/bin/bash
# DRAFT ONLY: build pinned NP2kai SDL frontend and stage PC-98 BIOS/media inputs.
set -euo pipefail
WORK="${WORK:-/data/vms/build-pc98}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/pc98}"
NP2_REPO="${NP2_REPO:-https://github.com/piepacker/np2kai.git}"
NP2_REF="${NP2_REF:-master}"
BIOS_DIR="${BIOS_DIR:-}"
DOS_MEDIA="${DOS_MEDIA:-}"
WIN31_MEDIA="${WIN31_MEDIA:-}"
mkdir -p "$WORK" "$ASSETS/bin" "$ASSETS/bios" "$ASSETS/media"
git clone "$NP2_REPO" "$WORK/np2kai"
( cd "$WORK/np2kai"; git checkout "$NP2_REF"; git rev-parse HEAD ) | tee "$WORK/np2kai.commit"
cmake -S "$WORK/np2kai" -B "$WORK/np2kai/build" -D BUILD_SDL=ON -D USE_SDL2=ON
cmake --build "$WORK/np2kai/build" -j"$(nproc)"
NP2_BIN="$(find "$WORK/np2kai/build" -type f -name 'sdlnp21kai*' -perm -111 -print -quit)"
[ -n "$NP2_BIN" ] || { echo "sdlnp21kai binary not found" >&2; exit 1; }
cp -f "$NP2_BIN" "$ASSETS/bin/sdlnp21kai"
[ -n "$BIOS_DIR" ] && cp -a "$BIOS_DIR/." "$ASSETS/bios/"
[ -n "$DOS_MEDIA" ] && cp -a "$DOS_MEDIA" "$ASSETS/media/"
[ -n "$WIN31_MEDIA" ] && cp -a "$WIN31_MEDIA" "$ASSETS/media/"
find "$ASSETS" -type f -print0 | sort -z | xargs -0 sha256sum >"$ASSETS/MANIFEST.sha256"
cat >&2 <<'EOF'
LAB STEP:
  run sdlnp21kai once with HOME/XDG_CONFIG_HOME under a scratch directory;
  install DOS 6.2 + Japanese Windows 3.1;
  enable WAB only after plain Windows output works;
  save the resulting np2kai config as assets/pc98/np2kai.cfg and the installed HDD as disk-seed.
EOF
