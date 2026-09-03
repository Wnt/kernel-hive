#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/freebsd411.sh — media/installer builder for the
# freebsd411 station (FreeBSD 4.11-RELEASE, i386, 2005) for the Kernel Hive
# (host-native streamhost, Tier 1). AUTOMATION LEVEL: assisted — sysinstall
# is a curses installer; the golden stream drives it interactively, this
# script only stages verified media and prints the launch line.
#
# Fetches from the pinned upstream mirror (PLAIN http — the https certificate
# on ftp-archive.freebsd.org does not match the host):
#   http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/i386/ISO-IMAGES/4.11/
#     4.11-RELEASE-i386-disc1-kde.iso
# into <STAGE_DIR> (default /data/assets-staging/freebsd411/), verifies the
# file against the SHA-256 pinned below (measured against the archive's own
# CHECKSUM.MD5, ftp-archive.freebsd.org 4.11-RELEASE i386 ISO-IMAGES) and
# creates a blank 4 GiB
#   <GUEST_DIR>/freebsd411.qcow2   (default /data/gallery-guests/FREEBSD411)
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED: pinned mirror, file SHA-256
#                        verified against the literal pin below.
#   (2) DISK CREATE .... `qemu-img create -f qcow2` blank 4 GiB, sysinstall
#                        partitions/formats it.
#   (3) INSTALL ........ ASSISTED — sysinstall is curses-driven; the golden
#                        stream types the sequence documented below.
#   (4) INPUT AUTOMATION none here; QMP typing lives in the golden stream.
#   (5) ERA SOFTWARE ... base + XFree86 4.3.0 + KDE 3.3.2 packages, all from
#                        the one disc (that is why this variant, not
#                        disc1-gnome or the miniinst discs).
#   (6) FINAL IMAGE .... freebsd411.qcow2
#   (7) VERIFY ......... none here — this script only stages media and
#                        creates a blank disk.
#
# sysinstall sequence (curses, typed by the golden stream — NOT automated here):
#   boot CD -> Kernel Configuration Menu -> Enter (skip)
#   -> sysinstall main menu -> Standard install
#   -> fdisk: a (use entire disk)              -> q (finish)
#   -> Boot Manager: BootMgr (or None, per golden stream's choice)
#   -> disklabel: a (auto-defaults)            -> q (finish)
#   -> Distributions: All, then "no" to the ports collection prompt
#   -> Media: CD/DVD
#   -> confirm install, let sysinstall extract the distribution
#   -> Post-install config: Network -> ed0, DHCP: Yes
#   -> Config -> Mouse: moused daemon, port /dev/psm0, protocol auto
#   -> Packages: browse CD packages, install kde-3.3.2 (pulls XFree86 4.3.0
#      and dependencies)
#   -> set root password
#   -> Exit sysinstall -> reboot, remove CD, boot from the hard disk
#
# Launch line (assisted install):
#   /opt/qemu-beos/bin/qemu-system-x86_64 -enable-kvm -m 256 -smp 1 \
#     -machine pc-i440fx-11.0,acpi=off -cpu host -rtc base=localtime -vga cirrus \
#     -drive file=freebsd411.qcow2,format=qcow2,if=ide \
#     -cdrom 4.11-RELEASE-i386-disc1-kde.iso -boot d \
#     -netdev user,id=n0,hostfwd=tcp:127.0.0.1:6078-10.0.2.15:6000 \
#     -device ne2k_pci,netdev=n0
# Usage:
#   build-guests/tiles/freebsd411.sh [--dir DIR] [--force] [-h]
#     --dir DIR   output/guest dir  (default /data/gallery-guests/FREEBSD411)
#     --force     re-fetch/re-verify/re-create even if valid outputs exist
#     -h|--help   show this header
#   env: STAGE_DIR  intake dir  (default /data/assets-staging/freebsd411)
# =============================================================================
set -euo pipefail
# ---- config -----------------------------------------------------------------
GUEST_DIR="/data/gallery-guests/FREEBSD411"
STAGE_DIR="${STAGE_DIR:-/data/assets-staging/freebsd411}"
OUT_NAME="freebsd411.qcow2"
DISK_SIZE="4G"
MIRROR="http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/i386/ISO-IMAGES/4.11"
ISO_NAME="4.11-RELEASE-i386-disc1-kde.iso"
PIN_SHA256="45a6094b377b041194d582c12daa8e6c1809872acb502e9c4a0f7c7cf19e7fd7"
PIN_BYTES="663328768"
PIN_MD5="84921fe6b6b4bfd3f7011788985d34e2"
FORCE=0

log() { printf '[build:freebsd411] %s\n' "$*" >&2; }
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
      sed -n '2,66p' "$0"
      exit 0
      ;;
    *) die "unknown arg: $1" ;;
  esac
done

mkdir -p "$STAGE_DIR"

fetch_and_verify() {
  local dest="$STAGE_DIR/$ISO_NAME"
  local url="$MIRROR/$ISO_NAME"
  if [ "$FORCE" -eq 0 ] && [ -f "$dest" ]; then
    local have
    have="$(sha256sum "$dest" | awk '{print $1}')"
    [ "$have" = "$PIN_SHA256" ] && {
      log "ok (cached): $ISO_NAME"
      return
    }
  fi
  log "fetching $ISO_NAME"
  curl -fsSL "$url" -o "$dest"
  local got
  got="$(sha256sum "$dest" | awk '{print $1}')"
  [ "$got" = "$PIN_SHA256" ] || die "sha256 mismatch for $ISO_NAME: got $got want $PIN_SHA256"
  local bytes
  bytes="$(stat -c %s "$dest")"
  [ "$bytes" = "$PIN_BYTES" ] || die "size mismatch for $ISO_NAME: got $bytes want $PIN_BYTES"
  log "verified $ISO_NAME ($bytes bytes, publisher MD5 $PIN_MD5)"
}

fetch_and_verify

# ---- disk -----------------------------------------------------------------
mkdir -p "$GUEST_DIR"
DISK="$GUEST_DIR/$OUT_NAME"
if [ "$FORCE" -eq 1 ] || [ ! -f "$DISK" ]; then
  log "creating blank ${DISK_SIZE} disk"
  qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
else
  log "ok (cached): $DISK"
fi

log "assisted install — drive sysinstall per the header comment, then launch:"
cat <<EOF
/opt/qemu-beos/bin/qemu-system-x86_64 -enable-kvm -m 256 -smp 1 \\
  -machine pc-i440fx-11.0,acpi=off -cpu host -rtc base=localtime -vga cirrus \\
  -drive file=$DISK,format=qcow2,if=ide \\
  -cdrom $STAGE_DIR/$ISO_NAME -boot d \\
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:6078-10.0.2.15:6000 \\
  -device ne2k_pci,netdev=n0
EOF
