#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/oberon.sh — station media for ETH Oberon System 3 /
# PC Native 2.3.6 (13 May 1999) in the Kernel Hive (Tier 1, fleet QEMU).
#
# GUEST: Native Oberon 2.3.6 — ETH Zurich's Oberon System 3 ("Gadgets") on a
#        bare PC, ETH Oberon licence (BSD-style, attribution). The install set
#        (Oberon0.Dsk installer floppy + NativeOberon_2.3.6.tar.gz, SourceForge
#        mirror of ftp.inf.ethz.ch/pub/ETHOberon/Native/) hits a known wall
#        under QEMU: the Oberon0 boot diskette stops at "Boot.Bin checksum
#        bad" (recorded by asig/native-oberon's README, whose author installed
#        under VirtualBox and converted the disk). This builder therefore
#        fetches that project's ready-installed raw IDE image — 1280x1024
#        VESA Gadgets desktop, all packages, NetNe2000pci driver — pinned by
#        sha256, and converts it to qcow2. The floppy install stays the
#        documented alternative (docs/guests/oberon.md).
#
# WHAT THIS SCRIPT DOES:
#   1. fetch the raw image into <STAGE_DIR>, verify the pinned SHA-256.
#   2. qemu-img convert raw -> qcow2 into <GUEST_DIR>/oberon.qcow2.
#   3. verify: boot it headless on the station's device set (KVM, i440fx,
#      -vga std, 64 MB, 1 vCPU, ne2k_pci on slirp restrict=on), wait for the
#      framebuffer to settle, assert a 1280x1024 non-blank frame, keep it as
#      verify-desktop.png.
#
# Usage:
#   build-guests/tiles/oberon.sh [--force] [--no-verify] [-h]
#   env: WORK        scratch dir  (default /data/vms/build-oberon)
#        STAGE_DIR   intake dir   (default /data/assets-staging/oberon)
#        GUEST_DIR   output dir   (default /data/gallery-guests/OBERON)
# =============================================================================
set -euo pipefail

STAGE_DIR="${STAGE_DIR:-/data/assets-staging/oberon}"
WORK="${WORK:-/data/vms/build-oberon}"
GUEST_DIR="${GUEST_DIR:-/data/gallery-guests/OBERON}"
OUT_NAME="oberon.qcow2"
IMG_NAME="NativeOberon-2.3.6-qemu-fallback.img"
UPSTREAM_URL="https://raw.githubusercontent.com/asig/native-oberon/master/2.3.6/Native%20Oberon%202.3.6.img"
IMG_SHA256="65f21c27cd62ceffab303d7266606f4db3c22e83be462f8a70a0f0ea4f8c60d1"
IMG_BYTES=83886080

FORCE=0
VERIFY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --no-verify)
      VERIFY=0
      shift
      ;;
    -h | --help)
      sed -n '2,31p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

OUT_PATH="${GUEST_DIR}/${OUT_NAME}"
QMPSOCK="${WORK}/qmp.sock"
PIDFILE="${WORK}/qemu.pid"
VERIFY_PNG="${GUEST_DIR}/verify-desktop.png"
FBWAIT="$(cd "$(dirname "$0")" && pwd)/../../dev/fb-wait.py"

log() { printf '\033[1;36m[oberon]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[oberon] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

stop_qemu() {
  local p=""
  [ -f "$PIDFILE" ] && p="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    kill -TERM "$p" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" "$QMPSOCK"
}
trap stop_qemu EXIT

for c in curl sha256sum qemu-img qemu-system-x86_64 python3; do
  command -v "$c" >/dev/null 2>&1 || die "need $c"
done
mkdir -p "$WORK" "$GUEST_DIR"
install -d -m 0750 "$STAGE_DIR"
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# (1) FETCH + PIN-VERIFY
IMG_PATH="${STAGE_DIR}/${IMG_NAME}"
if [ "$FORCE" = 1 ] || [ ! -s "$IMG_PATH" ] || [ "$(sha_of "$IMG_PATH")" != "$IMG_SHA256" ]; then
  log "fetching ${UPSTREAM_URL}"
  curl -fL --retry 3 -o "${IMG_PATH}.part" "$UPSTREAM_URL"
  mv "${IMG_PATH}.part" "$IMG_PATH"
fi
[ "$(stat -c%s "$IMG_PATH")" = "$IMG_BYTES" ] || die "size mismatch for $IMG_PATH (want $IMG_BYTES)"
[ "$(sha_of "$IMG_PATH")" = "$IMG_SHA256" ] || die "sha256 mismatch for $IMG_PATH (got $(sha_of "$IMG_PATH"), want $IMG_SHA256)"
log "image verified: $IMG_PATH ($IMG_BYTES bytes)"

# (2) CONVERT
if [ "$FORCE" = 0 ] && [ -s "$OUT_PATH" ]; then
  log "output already present at $OUT_PATH, skipping convert (use --force to rebuild)"
else
  qemu-img convert -f raw -O qcow2 "$IMG_PATH" "${OUT_PATH}.part"
  mv "${OUT_PATH}.part" "$OUT_PATH"
  log "wrote $OUT_PATH"
fi

# (3) VERIFY on the station device set (streamhost/stations/oberon/qemu-streamhost.sh)
if [ "$VERIFY" = 1 ]; then
  [ -f "$FBWAIT" ] || die "missing $FBWAIT"
  [ -f "$WORK/floppy-empty.img" ] || dd if=/dev/zero of="$WORK/floppy-empty.img" bs=1024 count=1440 status=none
  rm -f "$QMPSOCK" "$PIDFILE"
  qemu-system-x86_64 -name build-oberon -enable-kvm -m 64 -smp 1 \
    -machine pc-i440fx-11.0,acpi=off -cpu host -rtc base=localtime \
    -drive "file=$OUT_PATH,format=qcow2,if=ide,index=0,snapshot=on" \
    -drive "file=$WORK/floppy-empty.img,format=raw,if=floppy,index=0" \
    -boot c -vga std -display none \
    -netdev user,id=n0,restrict=on -device ne2k_pci,netdev=n0 \
    -qmp "unix:$QMPSOCK,server=on,wait=off" -pidfile "$PIDFILE" -daemonize
  python3 "$FBWAIT" --qmp "$QMPSOCK" --settle 6 --timeout 120 --out "$VERIFY_PNG" || die "framebuffer never settled"
  python3 - "$VERIFY_PNG" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
if im.size != (1280, 1024):
    sys.exit(f"unexpected mode {im.size}, want 1280x1024 (Oberon VESA desktop)")
colours = im.getcolors(1 << 20)
if colours is None or len(colours) < 3:
    sys.exit("frame is blank")
print(f"verify: {im.size} {len(colours)} colours -> OK")
PY
  log "verified: $VERIFY_PNG shows the Native Oberon desktop"
fi
log "done: $OUT_PATH"
