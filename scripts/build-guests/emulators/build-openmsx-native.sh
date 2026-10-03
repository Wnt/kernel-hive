#!/bin/bash
# Pinned host-native openMSX; run on labhost. Never uses the live asset tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="${OPENMSX_BUILD:-/data/vms/sandbox/msxturbor/build}"
DEST="${OPENMSX_DEST:-/data/vms/sandbox/msxturbor/assets/openmsx}"
PIN=cb61db762aba16752ff649990bf85e40627777af
SRC="$BUILD/openmsx"
mkdir -p "$BUILD"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch RELEASE_21_0 https://github.com/openMSX/openMSX.git "$SRC"
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$PIN" ]]
PATCH="$ROOT/streamhost/openmsx-patches/0001-native-outputs.patch"
if git -C "$SRC" apply --check "$PATCH" 2>/dev/null; then
  git -C "$SRC" apply "$PATCH"
else
  git -C "$SRC" apply --reverse --check "$PATCH"
fi
cp "$ROOT/streamhost/openmsx-patches/HiveOutput.hh" "$SRC/src/video/HiveOutput.hh"
# Upstream's compiler probe does not accept CXX='ccache g++'. The ccache
# masquerade executable is both its supported single compiler and a real cache.
export CCACHE_BASEDIR="$BUILD" CCACHE_NOHASHDIR=true
[[ -x /usr/lib/ccache/g++ ]]
ccache --show-stats
make -C "$SRC" -j"${JOBS:-6}" -l50 CXX=/usr/lib/ccache/g++ \
  INSTALL_BASE="$DEST" SYMLINK_FOR_BINARY=false
make -C "$SRC" install CXX=/usr/lib/ccache/g++ \
  INSTALL_BASE="$DEST.install" SYMLINK_FOR_BINARY=false
# Replace the executable by rename, including when a sandbox proof is running.
mkdir -p "$DEST/bin"
mv "$DEST.install/bin/openmsx" "$DEST/bin/openmsx"
cp -a "$DEST.install/share" "$DEST/"
rm -rf -- "$DEST.install"
ccache --show-stats
sha256sum "$DEST/bin/openmsx"
