#!/bin/bash
# tiles/vax43bsd.sh — build the `vax43bsd` station: 4.3BSD on a SIMH VAX-11/780.
#
# There is no QEMU guest and no checkpoint here. Like medley/lisa/perq/vision
# this is a host application in a container and reset = relaunch, so the
# builder's whole job is to produce three inert, hashed artifacts:
#
#   bin/vax780               Open SIMH's VAX-11/780 simulator, pinned
#   media/43.tap             the 4.3BSD distribution tape, built from TUHS files
#   media/bsd43-ra81.dsk     an RA81 image with 4.3BSD installed and HALTED CLEAN
#   rootfs/                  the Debian tree the station container runs inside
#
# The disk is built by actually installing 4.3BSD, driven over the simulator's
# console by scripts/build-guests/vax43bsd/simhdrive.py. That is slow to write
# and fast to run: the whole install measured under four minutes on labhost.
#
# Run FROM CT950 (it fetches over the WAN); every labhost step goes through
# scripts/dev/labrun. See docs/lab/VAX43BSD-WAVE.md for the measured facts, the
# device set, and what is still OPEN.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABRUN="$HERE/../../dev/labrun"
SRC="$HERE/../vax43bsd"
OS_ID="vax43bsd"

ASSETS="${VAX43BSD_ASSETS:-/data/vms/streamhost/assets/$OS_ID}"
STAGING="${VAX43BSD_STAGING:-/data/assets-staging/$OS_ID}"
WORK="${WORK:-/data/vms/build-$OS_ID}"
ROOTFS="${VAX43BSD_ROOTFS:-$ASSETS/rootfs}"
UIDBASE="${VAX43BSD_UIDBASE:-2490368}" # 38*65536; clear of medley/indyr4400/lisa

# The 4.3BSD directory is under UCB/4BSD/, NOT UCB/4.3BSD/ — the latter is the
# URL every install guide quotes and it 404s.
TUHS="${TUHS:-https://www.tuhs.org/Archive/Distributions/UCB/4BSD/4.3BSD}"
SIMH_REPO="${SIMH_REPO:-https://github.com/open-simh/simh.git}"
SIMH_REF="${SIMH_REF:-a1f57fa3738ed31148d31126ba1a7278ff845c6d}"
# SIMH cannot boot the emulated TS tape, so the 4.2BSD standalone boot is
# loaded at address 0 instead. The ?action=raw form below is the one that works.
BOOT42_URL="${BOOT42_URL:-https://gunkies.org/w/index.php?title=Boot42&action=raw}"
BOOT42_SHA=6600 # bytes, not a hash — see the size check below

# filename bytes sha256 — measured 2026-09-20, see docs/lab/VAX43BSD-WAVE.md
MEDIA="\
stand.gz 23894 8f5f38d1c141f598bf4fca16277960f463486f5d678e883a7de97af11ab148a2
miniroot.gz 533449 9f3c27b7ea99cec22b22a9eb8e25f85287087d031681476158e98b6ffffdebb5
rootdump.gz 1654236 46d1ab1c41c330be47b04812f779c7e535b3e0d4d251b03670455660b212b125
usr.tar.gz 9803428 8565ff6f85ade24a1b63fdc5f7f5befe49b70bf4d44281cbfb015742ba379cc4"

# A namespaced DZ port for the BUILD ONLY. The station's own listener lives
# inside the container's private network namespace and never reaches the host.
BUILD_DZ_PORT="${BUILD_DZ_PORT:-18209}"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }

usage() {
  cat >&2 <<EOF
usage: $0 [--media] [--simh] [--disk] [--rootfs] [--all]
  --media   stage and hash the TUHS distribution files + boot42
  --simh    build the pinned Open SIMH vax780
  --disk    install 4.3BSD onto a fresh RA81 image and halt it clean
  --rootfs  debootstrap the container tree and shift it to uid $UIDBASE
  --all     all of the above, in order (default)
EOF
  exit 2
}

do_media=0 do_simh=0 do_disk=0 do_rootfs=0
if [ $# -eq 0 ]; then
  do_media=1 do_simh=1 do_disk=1 do_rootfs=1
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --media) do_media=1 ;;
    --simh) do_simh=1 ;;
    --disk) do_disk=1 ;;
    --rootfs) do_rootfs=1 ;;
    --all) do_media=1 do_simh=1 do_disk=1 do_rootfs=1 ;;
    *) usage ;;
  esac
  shift
done

# --------------------------------------------------------------------------
# 1. media
# --------------------------------------------------------------------------
if [ "$do_media" = 1 ]; then
  log "staging the 4.3BSD distribution from $TUHS"
  "$LABRUN" <<EOF
set -euo pipefail
umask 022
mkdir -p "$STAGING"
cd "$STAGING"
for f in stand.gz miniroot.gz rootdump.gz usr.tar.gz FORMAT; do
  [ -s "\$f" ] || curl -fsSL -O "$TUHS/\$f"
done
printf '%s\n' "$MEDIA" | while read -r name size sha; do
  [ -z "\$name" ] && continue
  got="\$(stat -c %s "\$name")"
  [ "\$got" = "\$size" ] || { echo "\$name: \$got bytes, expected \$size" >&2; exit 1; }
  echo "\$sha  \$name" | sha256sum -c - >/dev/null
done
sha256sum ./* > MANIFEST.sha256
mkdir -p "$WORK"
cd "$WORK"
if [ ! -s boot42 ]; then
  curl -fsSL "$BOOT42_URL" -o boot42.wiki
  python3 - <<'PY'
import binascii, re
t = open('boot42.wiki', encoding='utf-8', errors='replace').read()
m = re.search(r'begin 700 boot42\n(.*?)\nend', t, re.S)
if not m:
    raise SystemExit('no uuencoded boot42 in the wiki page')
out = bytearray()
for ln in m.group(1).split('\n'):
    ln = ln.rstrip('\r')
    if not ln.strip() or ln.strip() == '\`':
        continue
    out += binascii.a2b_uu(ln)
open('boot42', 'wb').write(bytes(out))
PY
fi
got="\$(stat -c %s boot42)"
[ "\$got" = "$BOOT42_SHA" ] || { echo "boot42: \$got bytes, expected $BOOT42_SHA" >&2; exit 1; }
echo "media staged in $STAGING, boot42 in $WORK"
EOF
fi

# --------------------------------------------------------------------------
# 2. simulator
# --------------------------------------------------------------------------
if [ "$do_simh" = 1 ]; then
  log "building Open SIMH vax780 at $SIMH_REF"
  "$LABRUN" <<EOF
set -euo pipefail
umask 022
mkdir -p "$WORK"
cd "$WORK"
[ -d simh ] || git clone -q "$SIMH_REPO" simh
cd simh
git fetch -q origin
git checkout -q "$SIMH_REF"
nice make -j"\$(nproc)" vax780 >"$WORK/simh-build.log" 2>&1 || { tail -30 "$WORK/simh-build.log" >&2; exit 1; }
mkdir -p "$ASSETS/bin"
install -m 0555 BIN/vax780 "$ASSETS/bin/vax780"
"$ASSETS/bin/vax780" --version 2>&1 | head -2
EOF
fi

# --------------------------------------------------------------------------
# 3. the disk — a real install, driven over the simulator console
# --------------------------------------------------------------------------
if [ "$do_disk" = 1 ]; then
  log "installing 4.3BSD onto a fresh RA81 (this is the long step; ~4 min)"
  "$LABRUN" <<EOF
set -euo pipefail
umask 022
I="$WORK/inst"
rm -rf "\$I"; mkdir -p "\$I"; cd "\$I"
for f in stand miniroot rootdump usr.tar; do
  gzip -dc "$STAGING/\$f.gz" > "\$f"
done
cp "$WORK/boot42" boot42
python3 "$SRC/mktape.py" 43.tap
sed "s/att dz 18209/att dz $BUILD_DZ_PORT/" "$SRC/boot.ini" > boot.ini
cp "$SRC/install.ini" install.ini

drive() { # \$1 ini  \$2 expect script  \$3 log tag
  python3 "$SRC/simhdrive.py" "\$I" "$ASSETS/bin/vax780" "\$1" "\$2" "\$I/console-\$3.log"
}

drive install.ini "$SRC/install.exp" phase1
drive boot.ini    "$SRC/phase2.exp"  phase2
drive boot.ini    "$SRC/polish.exp"  polish
# The polish pass ends in a clean halt, but boot-time fsck may still have
# salvaged something on the pass before it; one more clean boot+halt makes the
# seed genuinely fsck-clean, which is worth ~10 s off every visitor's boot.
drive boot.ini    "$SRC/halt.exp"    seal

mkdir -p "$ASSETS/media"
cp --sparse=always -f "\$I/rq.dsk"  "$ASSETS/media/bsd43-ra81.dsk"
cp --sparse=always -f "\$I/43.tap"  "$ASSETS/media/43.tap"
cp -f "\$I/boot42" "$ASSETS/media/boot42"
chmod 0444 "$ASSETS/media"/*
cd "$ASSETS" && sha256sum bin/vax780 media/* > MANIFEST.sha256
cat MANIFEST.sha256
EOF

  log "proving the DZ visitor line (build-time; the station's proof is the framebuffer)"
  "$LABRUN" <<EOF
set -euo pipefail
I="$WORK/inst"
cd "\$I"
cp --sparse=always -f "$ASSETS/media/bsd43-ra81.dsk" rq.dsk
sed -e "s|<DZPORT>|$BUILD_DZ_PORT|" "$SRC/station-boot.ini" > station-boot.ini
setsid "$ASSETS/bin/vax780" station-boot.ini >"\$I/console-dz.log" 2>&1 </dev/null &
SIM=\$!
for _ in \$(seq 1 240); do
  grep -q KHBOOTREADY "\$I/console-dz.log" && break
  kill -0 "\$SIM" 2>/dev/null || { tail -30 "\$I/console-dz.log" >&2; exit 1; }
  sleep 0.5
done
grep -q KHBOOTREADY "\$I/console-dz.log" || { echo "no login prompt in 120 s" >&2; exit 1; }
python3 "$SRC/dzprobe.py" "$BUILD_DZ_PORT" | tee "\$I/dzprobe.out"
kill -9 "\$SIM" 2>/dev/null || true
grep -q VAXDZPROOFOK "\$I/console-dz.log" || { echo "the DZ session never reached the console" >&2; exit 1; }
echo "DZ visitor line proven on port $BUILD_DZ_PORT"
EOF
fi

# --------------------------------------------------------------------------
# 4. container rootfs
# --------------------------------------------------------------------------
if [ "$do_rootfs" = 1 ]; then
  log "building the container rootfs at $ROOTFS (uid base $UIDBASE)"
  "$LABRUN" <<EOF
set -euo pipefail
umask 022
R="$ROOTFS"
if [ -x "\$R/usr/bin/xterm" ] && [ "\$(stat -c %u "\$R")" = "$UIDBASE" ]; then
  echo "container rootfs present at \$R"; exit 0
fi
rm -rf "\$R.staging"
debootstrap --variant=minbase \
  --include=xvfb,xterm,xfonts-base,x11-utils,xauth,inetutils-telnet,netcat-openbsd,procps,util-linux,ncurses-term \
  trixie "\$R.staging" http://deb.debian.org/debian >"$WORK/debootstrap.log" 2>&1 \
  || { tail -20 "$WORK/debootstrap.log" >&2; exit 1; }
for b in Xvfb xterm telnet nc; do
  [ -x "\$R.staging/usr/bin/\$b" ] || { echo "no \$b in the container tree" >&2; exit 1; }
done
systemd-nspawn --quiet --register=no -D "\$R.staging" \
  --private-users=$UIDBASE:65536 --private-users-ownership=chown /bin/true
rm -rf "\$R"; mv "\$R.staging" "\$R"
echo "container rootfs built at \$R (\$(du -sh "\$R" | cut -f1), uid \$(stat -c %u "\$R"))"
EOF
fi

log "done — see docs/lab/VAX43BSD-WAVE.md"
