#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/netbsd14.sh — media/installer builder for the netbsd14
# station (NetBSD 1.4.1, i386, 1999) for the Kernel Hive (host-native
# streamhost, Tier 1). AUTOMATION LEVEL: assisted — sysinst is a curses
# installer; the golden stream drives it interactively, this script only
# stages verified media and prints the launch line.
#
# Fetches from the pinned upstream mirror:
#   http://archive.netbsd.org/pub/NetBSD-archive/NetBSD-1.4.1/i386/
#     installation/floppy/boot.fs
#     binary/sets/{base,comp,etc,games,kern,man,misc,text,xbase,xcomp,
#                  xcontrib,xfont,xserver}.tgz
# into <STAGE_DIR> (default /data/assets-staging/netbsd14/), verifies every
# file against the pinned SHA-256s in <STAGE_DIR>/MANIFEST.sha256 (read
# directly off the bind-mounted intake — never hand-typed here), composes
#   <STAGE_DIR>/sets.iso     via genisoimage -R -J -V NETBSD141
#     from a tree iso/i386/binary/sets/*.tgz
# and a 2 GiB
#   <GUEST_DIR>/netbsd14.qcow2   (default /data/gallery-guests/NETBSD14)
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED: pinned mirror, every file SHA-256
#                        verified against MANIFEST.sha256.
#   (2) DISK CREATE .... `qemu-img create -f qcow2` blank 2 GiB, sysinst
#                        partitions/formats it.
#   (3) INSTALL ........ ASSISTED — sysinst is curses-driven; the golden
#                        stream types the sequence documented below.
#   (4) INPUT AUTOMATION none here; QMP typing lives in the golden stream.
#   (5) ERA SOFTWARE ... base + X11 (XFree86 3.3.3.1) from the 13 sets.
#   (6) FINAL IMAGE .... netbsd14.qcow2
#   (7) VERIFY ......... none here — this script only stages media and
#                        prints the launch line; the golden stream proves it.
#
# sysinst sequence (curses, typed by the golden stream — NOT automated here):
#   boot from boot.fs -> a) Install NetBSD to hard disk
#   -> Keyboard: default (US)                 -> a
#   -> Disk: wd0, use whole disk               -> a wd0 -> Yes
#   -> Partition sizes: use existing/defaults  -> a -> x (accept)
#   -> Install from: CD-ROM/DVD                -> cd0, dir /i386/binary/sets
#   -> Sets: select ALL (base comp etc games kern man misc text xbase xcomp
#      xcontrib xfont xserver) -> x install
#   -> confirm install, let sysinst extract every set
#   -> configure timezone/rc, no X config needed here (XFree86 3.3.3.1 ships
#      in the sets; the golden stream configures XF86Config after first boot)
#   -> Exit sysinst -> reboot -> remove floppy/CD, boot wd0
#
# Launch line (assisted install; disk boots wd0 afterward with -boot c):
#   qemu-system-i386 -enable-kvm -machine pc-i440fx-11.0,acpi=off -cpu host \
#     -m 128 -vga cirrus \
#     -drive file=boot.fs,if=floppy,format=raw \
#     -drive file=netbsd14.qcow2,if=ide,format=qcow2 \
#     -cdrom sets.iso \
#     -netdev user,id=n0,hostfwd=tcp:127.0.0.1:6076-10.0.2.15:6000 \
#     -device ne2k_pci,netdev=n0 \
#     -boot a
#
# Usage:
#   build-guests/tiles/netbsd14.sh [--dir DIR] [--force] [-h]
#     --dir DIR   output/guest dir  (default /data/gallery-guests/NETBSD14)
#     --force     re-fetch/re-verify/re-compose even if valid outputs exist
#     -h|--help   show this header
#   env: STAGE_DIR  intake dir  (default /data/assets-staging/netbsd14)
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
GUEST_DIR="/data/gallery-guests/NETBSD14"
STAGE_DIR="${STAGE_DIR:-/data/assets-staging/netbsd14}"
OUT_NAME="netbsd14.qcow2"
DISK_SIZE="2G"
MIRROR="http://archive.netbsd.org/pub/NetBSD-archive/NetBSD-1.4.1/i386"
FLOPPY_REL="installation/floppy/boot.fs"
SETS=(base comp etc games kern man misc text xbase xcomp xcontrib xfont xserver)
FORCE=0

log() { printf '[build:netbsd14] %s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
  --dir)
    GUEST_DIR="$2"
    shift 2
    ;;
  --force)
    FORCE=1
    shift
    ;;
  -h | --help)
    sed -n '2,60p' "$0"
    exit 0
    ;;
  *) die "unknown arg: $1" ;;
  esac
done

MANIFEST="$STAGE_DIR/MANIFEST.sha256"
[ -f "$MANIFEST" ] || die "missing $MANIFEST — stage the pinned intake before running this script"

mkdir -p "$STAGE_DIR"

fetch_and_verify() {
  local rel="$1"
  local dest="$STAGE_DIR/$2"
  local url="$MIRROR/$rel"
  local want
  want="$(awk -v f="$2" '$2==f{print $1}' "$MANIFEST")"
  [ -n "$want" ] || die "no pinned hash for $2 in $MANIFEST"
  if [ "$FORCE" -eq 0 ] && [ -f "$dest" ]; then
    local have
    have="$(sha256sum "$dest" | awk '{print $1}')"
    [ "$have" = "$want" ] && {
      log "ok (cached): $2"
      return
    }
  fi
  mkdir -p "$(dirname "$dest")"
  log "fetching $2"
  curl -fsSL "$url" -o "$dest"
  local got
  got="$(sha256sum "$dest" | awk '{print $1}')"
  [ "$got" = "$want" ] || die "sha256 mismatch for $2: got $got want $want"
  local bytes
  bytes="$(stat -c %s "$dest")"
  log "verified $2 ($bytes bytes)"
}

fetch_and_verify "$FLOPPY_REL" "boot.fs"
for s in "${SETS[@]}"; do
  fetch_and_verify "binary/sets/${s}.tgz" "${s}.tgz"
done

# ---- compose sets.iso ---------------------------------------------------
ISO_TREE="$STAGE_DIR/iso"
ISO_OUT="$STAGE_DIR/sets.iso"
if [ "$FORCE" -eq 1 ] || [ ! -f "$ISO_OUT" ]; then
  rm -rf "$ISO_TREE"
  mkdir -p "$ISO_TREE/i386/binary/sets"
  for s in "${SETS[@]}"; do
    cp "$STAGE_DIR/${s}.tgz" "$ISO_TREE/i386/binary/sets/"
  done
  log "composing sets.iso"
  genisoimage -quiet -R -J -V NETBSD141 -o "$ISO_OUT" "$ISO_TREE"
else
  log "ok (cached): sets.iso"
fi

# ---- disk -----------------------------------------------------------------
mkdir -p "$GUEST_DIR"
DISK="$GUEST_DIR/$OUT_NAME"
if [ "$FORCE" -eq 1 ] || [ ! -f "$DISK" ]; then
  log "creating blank ${DISK_SIZE} disk"
  qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
else
  log "ok (cached): $DISK"
fi

log "assisted install — drive sysinst per the header comment, then launch:"
cat <<EOF
qemu-system-i386 -enable-kvm -machine pc-i440fx-11.0,acpi=off -cpu host \\
  -m 128 -vga cirrus \\
  -drive file=$STAGE_DIR/boot.fs,if=floppy,format=raw \\
  -drive file=$DISK,if=ide,format=qcow2 \\
  -cdrom $ISO_OUT \\
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:6076-10.0.2.15:6000 \\
  -device ne2k_pci,netdev=n0 \\
  -boot a
EOF
