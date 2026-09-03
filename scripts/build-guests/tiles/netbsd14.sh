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
# file against the SHA-256s pinned below (measured against the archive's own
# MD5s, archive.netbsd.org NetBSD-1.4.1/i386), composes
#   <STAGE_DIR>/sets.iso     via genisoimage -R -J -V NETBSD141
#     from a tree iso/i386/binary/sets/*.tgz
# and a 2 GiB
#   <GUEST_DIR>/netbsd14.qcow2   (default /data/gallery-guests/NETBSD14)
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED: pinned mirror, every file SHA-256
#                        verified against the literal pins below.
#   (2) DISK CREATE .... `qemu-img create -f qcow2` blank 2 GiB, sysinst
#                        partitions/formats it.
#   (3) INSTALL ........ ASSISTED — sysinst is curses-driven; the golden
#                        stream types the sequence documented below.
#   (4) INPUT AUTOMATION none here; QMP typing lives in the golden stream.
#   (5) ERA SOFTWARE ... base + X11 (XFree86 3.3.3.1) from the 13 sets.
#   (6) FINAL IMAGE .... netbsd14.qcow2
#   (7) VERIFY ......... none here — this script only stages media and
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
#   -> Exit sysinst -> KERNEL + X: tiles/netbsd14/README.md (GENERIC hangs on QEMU)
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
declare -A PIN_SHA=(
  ["boot.fs"]=5bbe8a5e9a28851d549a52506f0f94b21e7b962a863c6a13c6ce314e6ceb2e85
  ["base.tgz"]=342bb4631f237b2c22e5c8682b9cfeb63a39c38aa617e9f9020a709212a3e930
  ["comp.tgz"]=8af3d8253275667c4b1bb4401182a83cee90b450911d9b697e6d2055e7877232
  ["etc.tgz"]=8641cdbc4dc91cc77bcc4905ffdcf98be9ab400c52266474bfea406b80d38f93
  ["games.tgz"]=70f88300bff7df7df455a5f77851c30f7d0fe30f7c86909cc298c79ceae5b052
  ["kern.tgz"]=7e57e4080f9d67666ed95c88e309243745f7e96676c579e6c1131c12e8928924
  ["man.tgz"]=e45806509cdce23efbecd57f6889d257e0fe4faf898146f8679957a05bf8d8c5
  ["misc.tgz"]=9e27078392c728438732916e6ae695e66905d4570d987a9a3ed66ffb6ba47ae3
  ["text.tgz"]=60f2befdff6554c74ce8b601ccf67347164a26d183747b4a06bd0de2e1435af3
  ["xbase.tgz"]=8501d77e1869487c9853fc358443a799d40145405a4d1ee59179be9b15ae73fd
  ["xcomp.tgz"]=68134c7da74431f2d640a89acaf953b32cd267c3a93877f9cb421f360c12985c
  ["xcontrib.tgz"]=b7d429bae3636c28d92627e7688b2a00908c3efa0668cabe1d46df09e1c193ff
  ["xfont.tgz"]=edf9bf393678b0351399550f9025fccbd97d3d8d27ccc30ffc665ad9bfcb5e3b
  ["xserver.tgz"]=e4d98777ba2d95471f53ab751a6181c92f3cb2def641a1729cfa138317bdf462
)
declare -A PIN_BYTES=(
  ["boot.fs"]=1474560
  ["base.tgz"]=11582681
  ["comp.tgz"]=9136473
  ["etc.tgz"]=58786
  ["games.tgz"]=2948691
  ["kern.tgz"]=1548081
  ["man.tgz"]=4257176
  ["misc.tgz"]=2219614
  ["text.tgz"]=1350350
  ["xbase.tgz"]=2766863
  ["xcomp.tgz"]=1757456
  ["xcontrib.tgz"]=187851
  ["xfont.tgz"]=6172251
  ["xserver.tgz"]=16645498
)
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

mkdir -p "$STAGE_DIR"

fetch_and_verify() {
  local rel="$1"
  local dest="$STAGE_DIR/$2"
  local url="$MIRROR/$rel"
  local want="${PIN_SHA[$2]:-}"
  local want_bytes="${PIN_BYTES[$2]:-}"
  [ -n "$want" ] || die "no pinned hash for $2"
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
  [ "$bytes" = "$want_bytes" ] || die "size mismatch for $2: got $bytes want $want_bytes"
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
