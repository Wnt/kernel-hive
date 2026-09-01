#!/bin/bash
# build-fsuae-native.sh — pinned FS-UAE for the host-native FS-UAE stations
# (amigaos35 by default; FSUAE_STATION=amix for the Amiga UNIX station).
#
# Fetches the upstream 3.2.35 release tarball (sha256-verified), applies the
# lab's two patches from fsuae-native.d/ — the mousehack re-arm (without it
# every savestate restore leaves amigaos35's absolute mouse dead, see
# docs/guests/amigaos35.md) and the slirp hostfwd fix (stock 3.2.35 parses
# `slirp_redir` and then silently drops it; amix's x11warp pointer needs the
# loopback-only forward, see docs/guests/amix.md) — builds, and installs into
# the station assets tree. The golden statefile + this binary + the device set are ONE
# combination: rebuilding to a different FS-UAE version orphans the golden.
#
# Usage: [FSUAE_STATION=<station>] build-fsuae-native.sh [--no-install]
set -euo pipefail

VER=3.2.35
SHA256=f3d3cb8d3df34b0b0125c45a5a3e187ff71050be5dc8455cc4505c0380269117
URL="https://github.com/FrodeSolheim/fs-uae/releases/download/v${VER}/fs-uae-${VER}.tar.xz"
ASSETS_ROOT="${FSUAE_ASSETS_ROOT:-/data/vms/streamhost/assets}"
# Which station's asset tree gets this binary. Each station keeps its OWN copy:
# golden + binary + device set are ONE combination (AGENTS.md rule 6), so two
# stations sharing one binary means a rebuild for one orphans the other's
# golden. Defaults to amigaos35, the station this script was written for.
FSUAE_STATION="${FSUAE_STATION:-amigaos35}"
PREFIX="$ASSETS_ROOT/$FSUAE_STATION/fsuae-native"
WORK="${WORK:-/data/vms/sandbox/BUILD-fsuae}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES=(
  "$HERE/fsuae-native.d/fsuae-mousehack-rearm.patch"
  "$HERE/fsuae-native.d/fsuae-slirp-hostfwd.patch"
)

INSTALL=1
[ "${1:-}" = --no-install ] && INSTALL=0

for PATCH in "${PATCHES[@]}"; do
  [ -f "$PATCH" ] || {
    echo "missing $PATCH" >&2
    exit 1
  }
done

mkdir -p "$WORK"
cd "$WORK"
if [ ! -f "fs-uae-${VER}.tar.xz" ]; then
  curl -fsSL -o "fs-uae-${VER}.tar.xz.tmp" "$URL"
  mv "fs-uae-${VER}.tar.xz.tmp" "fs-uae-${VER}.tar.xz"
fi
echo "$SHA256  fs-uae-${VER}.tar.xz" | sha256sum -c -

rm -rf "fs-uae-${VER}"
tar xf "fs-uae-${VER}.tar.xz"
cd "fs-uae-${VER}"
for PATCH in "${PATCHES[@]}"; do
  patch -p1 <"$PATCH"
done

./configure --prefix="$PREFIX" >configure.log 2>&1
make -j"$(nproc)" >build.log 2>&1 || {
  tail -30 build.log >&2
  exit 1
}

if [ "$INSTALL" = 0 ]; then
  echo "built (no install): $WORK/fs-uae-${VER}/fs-uae"
  exit 0
fi

# Never clobber a binary the live golden depends on: back it up first.
if [ -x "$PREFIX/bin/fs-uae" ]; then
  cp -a "$PREFIX/bin/fs-uae" "$PREFIX/bin/fs-uae.bak-$(date +%Y%m%dT%H%M%S)"
fi
make install >install.log 2>&1
"$PREFIX/bin/fs-uae" --version </dev/null | head -1
echo "installed: $PREFIX/bin/fs-uae"
