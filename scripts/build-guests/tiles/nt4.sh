#!/usr/bin/env bash
# =============================================================================
# build-guests/nt4.sh — reproducible build of the Windows NT 4.0 Workstation
# SP6 tile for the Kernel Hive (GH #23, catalog §4).
#
# WHAT THIS BUILD IS (read before editing):
#   NT4 is NOT installed from an ISO here. We take a *preinstalled* NT4
#   Workstation SP6 VMware VM (archive.org, preservation-licensed), convert its
#   monolithicSparse VMDK to qcow2, then apply ONE offline fix so it boots under
#   QEMU/SeaBIOS i440fx:
#     boot.ini ARC path  scsi(0)disk(0)rdisk(0)partition(1)  ->  multi(0)...
#   The source VM was built on a BusLogic SCSI controller (scsi() path needs
#   ntbootdd.sys, which is absent); we present an IDE disk, so NTLDR must read it
#   via INT13h -> multi(). The NTFS BPB geometry (63 spt / 255 heads / hidden 63)
#   and MBR start-CHS already match SeaBIOS's 8 GiB translation, and atapi.sys is
#   already a boot-start driver, so NO MBR/VBR/registry surgery is needed (unlike
#   the win2000 image). See docs/guests/nt4.md for the full first-light record.
#
#   Verified end-to-end 2026-07-27: full NT4 Explorer desktop via auto-logon on
#   the `-cpu pentium3 -smp 1 -device VGA -device pcnet` recipe.
#
# AUTOMATION HONESTY:
#   (1) DOWNLOAD ... FULLY AUTOMATED (re-fetches the archive.org zip).
#   (2) CONVERT .... FULLY AUTOMATED (qemu-img convert VMDK -> qcow2).
#   (3) BOOT FIX ... FULLY AUTOMATED (offline ntfs-3g edit over qemu-nbd).
#   (4) GOLDEN ..... Stage 2, NOT here: bake `savevm golden` + remove VMware
#                    Tools + abs-pointer calibration on a namespaced clone.
#
# IDEMPOTENT: skips the download if the zip is cached; skips convert if the
# qcow2 already exists (override with --force). Namespaced work dir + a UNIQUE
# free /dev/nbdN.
# =============================================================================
set -euo pipefail

OS_ID="nt4"
GUEST_DIR="${GUEST_DIR:-/data/gallery-guests/Nt4}"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
SRC_URL="${SRC_URL:-https://archive.org/download/windows-nt-4.0-workstation-vmdk/Windows%20NT%20Workstation%204.0.zip}"
OUT_QCOW="$GUEST_DIR/nt4-golden.qcow2"
FORCE=0

for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --src-url=*) SRC_URL="${a#*=}" ;;
    *)
      echo "unknown arg: $a" >&2
      exit 2
      ;;
  esac
done

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

mkdir -p "$WORK" "$GUEST_DIR"

if [ -s "$OUT_QCOW" ] && [ "$FORCE" -eq 0 ]; then
  log "qcow2 already present ($OUT_QCOW); pass --force to rebuild. Done."
  exit 0
fi

# (1) DOWNLOAD -------------------------------------------------------------
ZIP="$WORK/nt4ws.zip"
if [ ! -s "$ZIP" ]; then
  log "downloading preinstalled NT4 VMware VM zip ..."
  curl -fSL --retry 3 -o "$ZIP" "$SRC_URL" || die "download failed: $SRC_URL"
fi

# (2) CONVERT --------------------------------------------------------------
VMDK="$WORK/Windows NT Workstation 4.0.vmdk"
[ -s "$VMDK" ] || unzip -o "$ZIP" -d "$WORK" >/dev/null || die "unzip failed"
[ -s "$VMDK" ] || die "vmdk not found after unzip: $VMDK"
log "converting VMDK -> qcow2 ..."
qemu-img convert -O qcow2 "$VMDK" "$OUT_QCOW" || die "qemu-img convert failed"

# (3) OFFLINE BOOT FIX: boot.ini scsi() -> multi() -------------------------
command -v qemu-nbd >/dev/null || die "qemu-nbd not installed"
modprobe nbd max_part=8 2>/dev/null || true
NBD=""
for n in $(seq 8 15); do
  if qemu-nbd -c "/dev/nbd$n" "$OUT_QCOW" 2>/dev/null; then
    NBD="/dev/nbd$n"
    break
  fi
done
[ -n "$NBD" ] || die "no free /dev/nbdN to attach the qcow2"
MNT="$WORK/mnt"
mkdir -p "$MNT"
cleanup() {
  umount "$MNT" 2>/dev/null || true
  [ -n "$NBD" ] && qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 1
mount -t ntfs-3g "${NBD}p1" "$MNT" || die "ntfs mount failed"
if grep -q 'scsi(0)disk(0)rdisk(0)partition(1)' "$MNT/boot.ini" 2>/dev/null; then
  sed -i 's/scsi(0)disk(0)rdisk(0)partition(1)/multi(0)disk(0)rdisk(0)partition(1)/g' "$MNT/boot.ini"
  log "boot.ini ARC path rewritten scsi(0) -> multi(0)"
else
  log "boot.ini already multi() or unexpected format; leaving as-is"
fi
umount "$MNT"
qemu-nbd -d "$NBD"
NBD=""
trap - EXIT

log "done: $OUT_QCOW"
log "NEXT (Stage 2): boot on the pinned device set (see streamhost/tiles/nt4/"
log "qemu-streamhost.sh), remove VMware Tools, calibrate the abs pointer,"
log "then bake 'savevm golden' and finalize registry/tiles/nt4.json."
