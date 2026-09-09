#!/usr/bin/env bash
# Build Red Hat Linux 6.2 "Zoot" as an unattended-kickstart gallery guest.
# All VM phases use -nodefaults and an explicit device ledger (redhat62-kickstart-cirrus-slirp).
set -euo pipefail
umask 077

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SELF_DIR/../../.." && pwd)
ASSET_DIR="$SELF_DIR/../assets/redhat62"
STAMP=${REDHAT62_BUILD_DATE:-$(date +%Y%m%d)}
WORK=${REDHAT62_WORK:-/data/vms/sandbox/redhat62-build-$STAMP}
STAGE=/data/assets-staging/redhat62
ISO=$STAGE/zoot-i386.iso
DISK=$WORK/redhat62.qcow2
QMP=$WORK/qmp.sock
HMP=$WORK/hmp.sock
PIDFILE=$WORK/qemu.pid
EVIDENCE=$WORK/evidence
FAILURES=$WORK/failures
OUT_DIR=${REDHAT62_OUT_DIR:-/data/gallery-guests/RedHat62}

ISO_URL=https://archive.org/download/redhat-6.2_release/zoot-i386.iso
ISO_SIZE=671881216
ISO_SHA256=dc8a1c86cc3389768af207101ecdc8f44e61bc8a5044cfb5fe0efb67eeaa9860

# The only prompt on a blank disk is "Bad Partition Table -> Initialize"; ide=nodma
# is the ledger's current pin, kept here as the default until the coordinator
# confirms it belongs on the boot line (REDHAT62-WAVE.md).
KS_BOOT_LINE=${KS_BOOT_LINE:-"text ks=floppy"}

log() { printf '[redhat62] %s\n' "$*"; }
die() {
  log "FAIL: $*" >&2
  if [ -S "$HMP" ]; then printf 'screendump %s/failure-%s.ppm\n' "$FAILURES" "$(date +%s)" | socat - UNIX-CONNECT:"$HMP" >/dev/null 2>&1 || true; fi
  exit 1
}

mkdir -p "$WORK" "$EVIDENCE" "$FAILURES"
[ "$WORK" != /mnt/poc ] || die "refusing /mnt/poc"
[[ "$WORK" == /data/vms/sandbox/redhat62-build-* ]] || die "WORK must be namespaced under /data/vms/sandbox/redhat62-build-*"

stage_media() {
  mkdir -p "$STAGE"
  if [ ! -s "$ISO" ]; then
    tmp=$STAGE/.zoot-i386.iso.$$.tmp
    trap 'rm -f "$tmp"' RETURN
    curl -fL --retry 5 --retry-delay 3 -o "$tmp" "$ISO_URL"
    [ "$(stat -c %s "$tmp")" = "$ISO_SIZE" ] || die "ISO size mismatch"
    printf '%s  %s\n' "$ISO_SHA256" "$tmp" | sha256sum -c - >/dev/null || die "ISO hash mismatch"
    mv "$tmp" "$ISO"
    trap - RETURN
  fi
  [ "$(stat -c %s "$ISO")" = "$ISO_SIZE" ] || die "staged ISO size mismatch"
  printf '%s  %s\n' "$ISO_SHA256" "$ISO" | sha256sum -c - >/dev/null || die "staged ISO hash mismatch"
  printf '%s  %s\n' "$ISO_SHA256" zoot-i386.iso >"$STAGE/MANIFEST.sha256.tmp"
  mv "$STAGE/MANIFEST.sha256.tmp" "$STAGE/MANIFEST.sha256"
}

make_ks_floppy() {
  [ -f "$ASSET_DIR/ks.cfg" ] || die "missing $ASSET_DIR/ks.cfg"
  rm -f "$WORK/ks.img"
  mformat -C -f 1440 -i "$WORK/ks.img" ::
  mcopy -i "$WORK/ks.img" "$ASSET_DIR/ks.cfg" ::ks.cfg
}

vm_stop() {
  [ -f "$PIDFILE" ] || return 0
  pid=$(cat "$PIDFILE")
  if kill -0 "$pid" 2>/dev/null; then
    [ -S "$HMP" ] && printf 'quit\n' | socat - UNIX-CONNECT:"$HMP" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 80); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && die "QEMU pid $pid did not stop"
  fi
  rm -f "$PIDFILE" "$QMP" "$HMP"
}
trap vm_stop EXIT

vm_start() {
  vm_stop
  [ -c /dev/kvm ] || die "/dev/kvm missing"
  qemu-system-x86_64 -machine help | grep -q 'pc-i440fx-11.0' || die "pc-i440fx-11.0 unavailable"
  qemu-system-x86_64 \
    -name build-redhat62 -nodefaults \
    -enable-kvm -machine pc-i440fx-11.0 -cpu host -m 256 -smp 1 -rtc base=localtime \
    -drive file="$DISK",format=qcow2,if=ide,index=0 \
    -drive file="$ISO",format=raw,media=cdrom,if=ide,index=2,readonly=on \
    -drive file="$WORK/ks.img",format=raw,if=floppy,index=0 \
    -boot order=d \
    -vga cirrus \
    -netdev user,id=n0 -device ne2k_pci,netdev=n0 \
    -display none \
    -qmp unix:"$QMP",server=on,wait=off \
    -monitor unix:"$HMP",server,nowait -pidfile "$PIDFILE" \
    -daemonize -D "$WORK/qemu.log"
  for _ in $(seq 1 120); do
    [ -S "$QMP" ] && [ -S "$HMP" ] && [ -f "$PIDFILE" ] && return
    sleep 0.25
  done
  die "QEMU sockets did not appear"
}

hmp() { printf '%s\n' "$1" | socat - UNIX-CONNECT:"$HMP" >/dev/null; }
shot() { hmp "screendump $EVIDENCE/$1.ppm"; }
fbwait() { # label, extra fb-wait.py args...
  local label=$1
  shift
  python3 "$REPO/scripts/dev/fb-wait.py" --qmp "$QMP" "$@" || die "fb-wait ($label) failed"
}

install_guest() {
  [ ! -e "$DISK" ] || die "fresh install refuses existing $DISK (move it aside explicitly)"
  qemu-img create -f qcow2 "$DISK.tmp" 4G >/dev/null
  mv "$DISK.tmp" "$DISK"
  make_ks_floppy
  vm_start
  # boot: type the kickstart boot line, then hit the LILO/syslinux prompt
  python3 "$REPO/scripts/dev/qmp-type.py" --qmp "$QMP" "$KS_BOOT_LINE" --keys ret
  # only interactive prompt on a blank disk: "Bad Partition Table -> Initialize"
  fbwait boot-settle --settle 15 --timeout 120
  hmp "sendkey ret"
  # install runs unattended from here; the "Complete" screen settles for >= 60s
  fbwait install-complete --settle 60 --timeout 3600
  shot installer-complete
  hmp "sendkey ret"
  fbwait post-reboot --change --timeout 300
  vm_stop
}

publish() {
  mkdir -p "$OUT_DIR"
  cp "$DISK" "$OUT_DIR/redhat62.qcow2.tmp"
  mv "$OUT_DIR/redhat62.qcow2.tmp" "$OUT_DIR/redhat62.qcow2"
  log "installed disk at $OUT_DIR/redhat62.qcow2 (golden capture is the golden stream's job, not this builder)"
}

main() {
  stage_media
  if [ "${1:-}" = "--stage-only" ]; then
    make_ks_floppy
    log "stage-only: ISO staged at $ISO, ks floppy built at $WORK/ks.img"
    log "QEMU command:"
    cat <<CMD
qemu-system-x86_64 -name build-redhat62 -nodefaults -enable-kvm -machine pc-i440fx-11.0 -cpu host -m 256 -smp 1 -rtc base=localtime -drive file=$DISK,format=qcow2,if=ide,index=0 -drive file=$ISO,format=raw,media=cdrom,if=ide,index=2,readonly=on -drive file=$WORK/ks.img,format=raw,if=floppy,index=0 -boot order=d -vga cirrus -netdev user,id=n0 -device ne2k_pci,netdev=n0 -display none -qmp unix:$QMP,server=on,wait=off -monitor unix:$HMP,server,nowait -pidfile $PIDFILE
CMD
    return 0
  fi
  install_guest
  publish
}

main "$@"
