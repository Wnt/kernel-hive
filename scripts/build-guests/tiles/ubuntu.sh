#!/usr/bin/env bash
# Build Ubuntu 4.10 Warty Warthog as a live-CD Tier 1 gallery guest.
# The CD is the OS: no install, the qcow2 is only the (initially empty)
# vmstate carrier. Never overwrite one that already has a `golden` snapshot.
set -euo pipefail
umask 077

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STAGE=/data/assets-staging/ubuntu
ISO=$STAGE/warty-release-live-i386.iso
ISO_URL=http://old-releases.ubuntu.com/releases/4.10/warty-release-live-i386.iso
ISO_SIZE=674152448
ISO_SHA256=189746859b539c37d978b107589610aa49a7415f7c089d22667867a918591013

STAMP=${UBUNTU_BUILD_DATE:-$(date +%Y%m%d)}
WORK=${UBUNTU_WORK:-/data/vms/sandbox/ubuntu-build-$STAMP}
OUT_DIR=${UBUNTU_OUT_DIR:-/data/gallery-guests/Ubuntu}
DISK=$WORK/ubuntu.qcow2
QMP=$WORK/qmp.sock
PIDFILE=$WORK/qemu.pid

log() { printf '[ubuntu] %s\n' "$*"; }
die() {
  log "FAIL: $*" >&2
  exit 1
}

mkdir -p "$WORK"
[[ "$WORK" == /data/vms/sandbox/ubuntu-build-* ]] || die "WORK must be namespaced under /data/vms/sandbox/ubuntu-build-*"

stage_media() {
  mkdir -p "$STAGE"
  if [ ! -s "$ISO" ]; then
    log "fetching $ISO_URL"
    wget -c -O "$ISO" "$ISO_URL"
  fi
  local size
  size=$(stat -c %s "$ISO")
  [ "$size" = "$ISO_SIZE" ] || die "ISO size mismatch: got $size want $ISO_SIZE"
  printf '%s  %s\n' "$ISO_SHA256" "$ISO" | sha256sum -c - >/dev/null || die "ISO sha256 mismatch"
  log "ISO verified: $ISO ($ISO_SIZE bytes)"
}

make_disk() {
  qemu-img create -f qcow2 "$DISK" 1G >/dev/null
  log "created $DISK"
}

install_pair() {
  mkdir -p "$OUT_DIR"
  local dest_iso=$OUT_DIR/warty-release-live-i386.iso
  local dest_qcow=$OUT_DIR/ubuntu.qcow2

  if [ -s "$dest_qcow" ] && [ "${FORCE:-0}" != 1 ]; then
    if qemu-img snapshot -l "$dest_qcow" 2>/dev/null | grep -q ' golden '; then
      die "$dest_qcow already has a golden snapshot; set FORCE=1 to override"
    fi
  fi

  local tmp_iso=$OUT_DIR/.warty-release-live-i386.iso.$$.tmp
  local tmp_qcow=$OUT_DIR/.ubuntu.qcow2.$$.tmp
  trap 'rm -f "$tmp_iso" "$tmp_qcow"' RETURN

  cp "$ISO" "$tmp_iso"
  cp "$DISK" "$tmp_qcow"
  mv "$tmp_iso" "$dest_iso"
  mv "$tmp_qcow" "$dest_qcow"
  trap - RETURN

  log "installed $dest_iso"
  log "installed $dest_qcow"
}

verify_boot() {
  [ "${VERIFY:-0}" = 1 ] || return 0
  local fbwait="$SELF_DIR/../../dev/fb-wait.py"
  [ -x "$fbwait" ] || fbwait=(python3 "$SELF_DIR/../../dev/fb-wait.py")
  log "VERIFY=1: booting exact launcher device set"
  qemu-system-x86_64 -nodefaults -enable-kvm \
    -machine pc-i440fx-11.0,acpi=off -cpu host -m 512 -smp 1 \
    -rtc base=localtime \
    -drive file="$WORK/verify.qcow2",if=ide,index=0 \
    -drive file="$ISO",if=ide,index=2,media=cdrom,readonly=on \
    -boot order=d \
    -vga std -usb -device usb-tablet \
    -display dbus,p2p=on \
    -qmp "unix:$QMP,server,nowait" \
    -pidfile "$PIDFILE" \
    -daemonize
  python3 "$SELF_DIR/../../dev/fb-wait.py" --qmp "$QMP" --settle 15 --timeout 240 --out "$WORK/fb.png" \
    || die "verify boot: no framebuffer settle"
  log "verify: framebuffer settled, see $WORK/fb.png"
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
  fi
}

stage_media
make_disk
if [ "${VERIFY:-0}" = 1 ]; then
  cp "$DISK" "$WORK/verify.qcow2"
  verify_boot
fi
install_pair
log "done"
