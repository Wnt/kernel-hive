#!/bin/bash
# tiles/its.sh — build MIT ITS for the `its` station from source, and build the
# container root the station runs inside.
#
# There is no ROM/ISO to fetch: the maintained github.com/PDP-10/its tree
# assembles the whole system (ITS itself plus its programs) and leaves the
# result — a bootable RP06 disk image and the SIMH PDP-10 (KS10) binary that
# boots it — in `out/simh`. The upstream commit is pinned here; the build is
# fully reproducible from it.
#
# Run FROM CT950; the heavy work goes to labhost through labrun (the build
# needs a compiler, expect, ncurses, autoconf and SDL2, and debootstrap for the
# container root).
#
# Measured 2026-09-20 on labhost: clone+submodules ~90 s, SIMH compile ~3 min,
# ITS self-assembly (the long pole; the build boots ITS in the simulator and
# assembles the sources inside it) still running at 22 min when the run was
# stood down for the box load rule. Budget ~30 min for a cold build and run it
# on a quiet box.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABRUN="$HERE/../../dev/labrun"
OS_ID="its"
ITS_REPO="${ITS_REPO:-https://github.com/PDP-10/its.git}"
# Pinned upstream commit (PDP-10/its master, fetched 2026-09-20).
ITS_REF="${ITS_REF:-0f7d67997f9f5d30208e117e73272031e74f16b9}"
ASSETS="${ITS_ASSETS:-/data/vms/streamhost/assets/its}"
WORK="${WORK:-/data/vms/build-its}"
UIDBASE="${ITS_UIDBASE:-2424832}" # 37*65536; clear of medley/indyr4400/vision/perq
ROOTFS="${ITS_ROOTFS:-$ASSETS/rootfs}"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }

# --- 1. the ITS system itself ------------------------------------------------
"$LABRUN" <<EOF
umask 022
set -eu
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
  expect autoconf automake libncurses-dev libsdl2-dev build-essential pkg-config >/dev/null
mkdir -p "$WORK"
cd "$WORK"
[ -d its/.git ] || git clone --recursive "$ITS_REPO" its
cd its
git fetch origin
git checkout "$ITS_REF"
git submodule update --init --recursive
git rev-parse HEAD >"$WORK/its.commit"
make EMULATOR=simh
[ -f out/simh/rp0.dsk ] || { echo "its: build left no out/simh/rp0.dsk" >&2; exit 1; }
[ -x tools/simh/BIN/pdp10 ] || { echo "its: build left no SIMH pdp10 binary" >&2; exit 1; }
# Atomic stage: the station binds \$ASSETS/tree read-only at this host path.
rm -rf "$ASSETS/tree.staging"
mkdir -p "$ASSETS"
cp -a "$WORK/its" "$ASSETS/tree.staging"
rm -rf "$ASSETS/tree.old"
[ -d "$ASSETS/tree" ] && mv "$ASSETS/tree" "$ASSETS/tree.old"
mv "$ASSETS/tree.staging" "$ASSETS/tree"
rm -rf "$ASSETS/tree.old"
chmod -R a+rX "$ASSETS/tree"
{
  echo "upstream $ITS_REPO"
  echo "commit   \$(cat "$WORK/its.commit")"
  printf 'rp0.dsk  %s bytes  %s\n' "\$(stat -c %s "$ASSETS/tree/out/simh/rp0.dsk")" \
    "\$(sha256sum "$ASSETS/tree/out/simh/rp0.dsk" | cut -d' ' -f1)"
  printf 'pdp10    %s bytes  %s\n' "\$(stat -c %s "$ASSETS/tree/tools/simh/BIN/pdp10")" \
    "\$(sha256sum "$ASSETS/tree/tools/simh/BIN/pdp10" | cut -d' ' -f1)"
} >"$ASSETS/MANIFEST.sha256"
cat "$ASSETS/MANIFEST.sha256"
EOF
log "ITS tree staged at $ASSETS/tree"

# --- 2. the container root ---------------------------------------------------
# Minimal Debian trixie with Xvfb, xterm and telnet — the visitor surface and
# nothing else. Built once and uid-shifted into the container's range
# (--private-users-ownership=chown cannot be combined with the volatile root
# the launcher uses, so the shift happens here and the launcher runs with
# ownership=off). Idempotent.
"$LABRUN" <<EOF
umask 022
set -eu
R="$ROOTFS"
if [ -x "\$R/usr/bin/xterm" ] && [ "\$(stat -c %u "\$R")" = "$UIDBASE" ]; then
  echo "its: container rootfs present at \$R (uid \$(stat -c %u "\$R"))"; exit 0
fi
rm -rf "\$R.staging"; mkdir -p "\$R.staging"
debootstrap --variant=minbase \
  --include=xvfb,xterm,xauth,x11-utils,xdotool,telnet,netcat-openbsd,procps,iproute2,util-linux,libbsd0,ncurses-term,xfonts-base,fontconfig,fonts-dejavu-core \
  trixie "\$R.staging" http://deb.debian.org/debian >"\$R.staging.log" 2>&1 \
  || { tail -20 "\$R.staging.log" >&2; exit 1; }
systemd-nspawn --quiet --register=no -D "\$R.staging" \
  --private-users=$UIDBASE:65536 --private-users-ownership=chown /bin/true
rm -rf "\$R"; mv "\$R.staging" "\$R"; rm -f "\$R.staging.log"
echo "its: container rootfs built at \$R (\$(du -sh "\$R" | cut -f1), uid $UIDBASE)"
EOF
log "container rootfs ready at $ROOTFS"
