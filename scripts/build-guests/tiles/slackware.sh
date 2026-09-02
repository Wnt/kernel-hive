#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/slackware.sh — from-scratch build of the Slackware 3.4
# station media for the Kernel Hive (host-native streamhost, Tier 1).
#
# GUEST: Slackware Linux 3.4 (1997, kernel 2.0.30), composed host-side from
#        the mirror .tgz package set — no interactive setup, no floppy dance.
#
# WHAT THIS SCRIPT DOES:
#   1. pin-verify (and fetch if absent) the 128-file asset set from the
#      Slackware 3.4 mirror against scripts/build-guests/tiles/slackware/
#      MANIFEST.sha256 (copied in from /data/assets-staging/slackware — the
#      coordinator's spine work already staged and hashed it there).
#   2. compose the disk host-side via tiles/slackware/compose.sh (installs
#      the pinned package set onto a raw ext2 image, writes XF86Config /
#      lilo.conf / rc.local autostart, ~12s as root on labhost).
#   3. build a GRUB2 boot ISO (grub-mkrescue) around the zImage — LILO from
#      1997 wedges at "LI" under SeaBIOS, and QEMU -kernel hangs this zImage,
#      so GRUB2's linux16 is the boot path.
#   4. ship both to /data/gallery-guests/Slackware/ with sha256 sidecars.
#   5. verify: boot a scratch copy on the pinned device set (see
#      tiles/slackware/launch-smoke.sh), fb-wait.py for a settled frame,
#      fail if it looks blank/text-mode.
#
# Usage:
#   build-guests/tiles/slackware.sh [--force] [--no-verify] [-h]
#   env: WORK        scratch dir  (default /data/vms/build-slackware)
#        STAGE_DIR   intake dir   (default /data/assets-staging/slackware)
#        GUEST_DIR   output dir   (default /data/gallery-guests/Slackware)
# =============================================================================
set -euo pipefail

STAGE_DIR="${STAGE_DIR:-/data/assets-staging/slackware}"
WORK="${WORK:-/data/vms/build-slackware}"
GUEST_DIR="${GUEST_DIR:-/data/gallery-guests/Slackware}"
MIRROR="https://mirrors.slackware.com/slackware/slackware-3.4"

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
      sed -n '2,28p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
LABQMP="$HERE/../../lib/labqmp.py"
FBWAIT="$HERE/../../dev/fb-wait.py"
TILE_DIR="$HERE/slackware"
MANIFEST="$TILE_DIR/MANIFEST.sha256"
QCOW2_OUT="${GUEST_DIR}/slackware.qcow2"
ISO_OUT="${GUEST_DIR}/grub-boot.iso"
QMPSOCK="${WORK}/verify/qmp.sock"
PIDFILE="${WORK}/verify/qemu.pid"
VERIFY_PNG="${GUEST_DIR}/verify-desktop.png"

log() { printf '\033[1;36m[slackware]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[slackware] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

stop_qemu() {
  local p=""
  [ -f "$PIDFILE" ] && p="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    kill -TERM "$p" 2>/dev/null || true
    for _ in 1 2 3 4 5 6; do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" "$QMPSOCK"
}
trap stop_qemu EXIT

for c in curl python3 sha256sum qemu-img grub-mkrescue qemu-system-x86_64; do
  command -v "$c" >/dev/null 2>&1 || die "need $c"
done
[ -f "$MANIFEST" ] || die "missing $MANIFEST"

mkdir -p "$WORK" "$WORK/verify" "$GUEST_DIR"
install -d -m 0750 "$STAGE_DIR"

# =============================================================================
# (1) FETCH + PIN-VERIFY the mirror asset set
# =============================================================================
log "checking $(wc -l <"$MANIFEST") pinned files against $STAGE_DIR"
while read -r want_sha rel; do
  rel="${rel#./}"
  case "$rel" in
    zImage | color.gz | bare.i.img | grub-boot.iso) dest="$STAGE_DIR/$rel" ;;
    *) dest="$STAGE_DIR/slakware/$rel" ;;
  esac
  got_sha="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')"
  if [ "$FORCE" = 1 ] || [ "$got_sha" != "$want_sha" ]; then
    mkdir -p "$(dirname "$dest")"
    log "fetching $rel"
    curl -fsSL --retry 3 -o "${dest}.part" "$MIRROR/$rel"
    mv "${dest}.part" "$dest"
    got_sha="$(sha256sum "$dest" | awk '{print $1}')"
  fi
  [ "$got_sha" = "$want_sha" ] || die "sha256 mismatch for $rel (got $got_sha, want $want_sha)"
done <"$MANIFEST"
log "asset set verified: $(wc -l <"$MANIFEST") files"

if [ "$FORCE" = 0 ] && [ -s "$QCOW2_OUT" ] && [ -s "$ISO_OUT" ]; then
  log "outputs already present in $GUEST_DIR, skipping compose (use --force to rebuild)"
else
  # ===========================================================================
  # (2) COMPOSE the disk host-side
  # ===========================================================================
  log "composing root fs + disk image"
  SRC="$STAGE_DIR/slakware" OUT="$WORK/build" "$TILE_DIR/compose.sh"
  [ -s "$WORK/build/disk.qcow2" ] || die "compose.sh did not produce disk.qcow2"

  # ===========================================================================
  # (3) BUILD the GRUB2 boot ISO around the pinned zImage
  # ===========================================================================
  log "building grub-boot.iso"
  ISO_DIR="$WORK/isoroot"
  rm -rf "$ISO_DIR"
  mkdir -p "$ISO_DIR/boot/grub"
  cp "$STAGE_DIR/zImage" "$ISO_DIR/zImage"
  cat >"$ISO_DIR/boot/grub/grub.cfg" <<'GRUBCFG'
set timeout=0
set default=0
menuentry "Slackware 3.4 (kernel 2.0.30 bare.i)" {
  linux16 /zImage root=/dev/hda1 ro
}
GRUBCFG
  grub-mkrescue -o "$WORK/grub-boot.iso" "$ISO_DIR" >/dev/null 2>&1
  [ -s "$WORK/grub-boot.iso" ] || die "grub-mkrescue did not produce grub-boot.iso"

  # ===========================================================================
  # (4) SHIP to the gallery with sha256 sidecars
  # ===========================================================================
  cp "$WORK/build/disk.qcow2" "$QCOW2_OUT"
  cp "$WORK/grub-boot.iso" "$ISO_OUT"
  sha256sum "$QCOW2_OUT" | awk '{print $1}' >"${QCOW2_OUT}.sha256"
  sha256sum "$ISO_OUT" | awk '{print $1}' >"${ISO_OUT}.sha256"
  log "output: $QCOW2_OUT ($(stat -c%s "$QCOW2_OUT") bytes)"
  log "output: $ISO_OUT ($(stat -c%s "$ISO_OUT") bytes)"
fi

[ "$VERIFY" = 1 ] || {
  log "skipping verify (--no-verify)"
  exit 0
}

# =============================================================================
# (5) VERIFY: boot a scratch copy on the pinned device set, fb-wait for the
#     settled desktop, fail on a blank/text-mode frame.
# =============================================================================
log "verify: booting a scratch copy"
rm -rf "$WORK/verify"
mkdir -p "$WORK/verify"
qemu-img create -f qcow2 -F qcow2 -b "$QCOW2_OUT" "$WORK/verify/disk.qcow2" >/dev/null

"$TILE_DIR/launch-smoke.sh" "$WORK/verify"

log "waiting for the desktop to settle"
python3 "$FBWAIT" --qmp "$QMPSOCK" --settle 10 --timeout 150 --out "$VERIFY_PNG"

[ -s "$VERIFY_PNG" ] || die "fb-wait did not produce $VERIFY_PNG"
PNG_SIZE="$(stat -c%s "$VERIFY_PNG")"
log "verify frame: $VERIFY_PNG ($PNG_SIZE bytes)"
[ "$PNG_SIZE" -gt 8192 ] || die "verify frame too small ($PNG_SIZE bytes) — looks like text mode or black screen"

log "build-guests/tiles/slackware.sh done: $QCOW2_OUT, $ISO_OUT, verify frame $VERIFY_PNG"
