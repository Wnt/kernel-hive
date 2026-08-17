#!/usr/bin/env bash
# Build Red Star OS 2.0 as an air-gapped, loadvm-resettable gallery guest.
# All VM phases use -nodefaults and an explicit device ledger with no NIC.
set -euo pipefail
umask 077

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ASSET_DIR="$SELF_DIR/../assets/redstar2"
STAMP=${REDSTAR2_BUILD_DATE:-$(date +%Y%m%d)}
WORK=${REDSTAR2_WORK:-/data/vms/sandbox/redstar2-build-$STAMP}
STAGE=/data/assets-staging/redstar2
ISO=$STAGE/redstar.iso
DISK=$WORK/redstar2.qcow2
FIX_TREE=$WORK/fix-cd
FIX_ISO=$WORK/redstar2-fix.iso
QMP=$WORK/qmp.sock
HMP=$WORK/hmp.sock
PIDFILE=$WORK/qemu.pid
EVIDENCE=$WORK/evidence
FAILURES=$WORK/failures
OUT_DIR=${REDSTAR2_OUT_DIR:-/data/gallery-guests/RedStar2}

ISO_URL=https://archive.org/download/redstar_20181224/redstar.iso
ISO_SIZE=1416017920
ISO_SHA256=69a45d07c302782cb777d03abd39c5b45b4099e5c994a74a77bb71ab5d229997

PASSWORD_FD=${REDSTAR2_PASSWORD_FD:-3}
if ! IFS= read -r -u "$PASSWORD_FD" GUEST_PASSWORD; then
  echo "redstar2: supply the credentials.ts password on fd $PASSWORD_FD" >&2
  exit 2
fi
[ -n "$GUEST_PASSWORD" ] || {
  echo "redstar2: empty password" >&2
  exit 2
}

log() { printf '[redstar2] %s\n' "$*"; }
die() {
  log "FAIL: $*" >&2
  if [ -S "$HMP" ]; then printf 'screendump %s/failure-%s.ppm\n' "$FAILURES" "$(date +%s)" | socat - UNIX-CONNECT:"$HMP" >/dev/null 2>&1 || true; fi
  exit 1
}

mkdir -p "$WORK" "$EVIDENCE" "$FAILURES"
[ "$WORK" != /mnt/poc ] || die "refusing /mnt/poc"
[[ "$WORK" == /data/vms/sandbox/redstar2-build-* ]] || die "WORK must be namespaced under /data/vms/sandbox/redstar2-build-*"
[ -c /dev/kvm ] || die "/dev/kvm missing"
qemu-system-x86_64 -machine help | grep -q 'pc-i440fx-11.0' || die "pc-i440fx-11.0 unavailable"

stage_media() {
  mkdir -p "$STAGE"
  if [ ! -s "$ISO" ]; then
    tmp=$STAGE/.redstar.iso.$$.tmp
    trap 'rm -f "$tmp"' RETURN
    curl -fL --retry 5 --retry-delay 3 -o "$tmp" "$ISO_URL"
    [ "$(stat -c %s "$tmp")" = "$ISO_SIZE" ] || die "ISO size mismatch"
    printf '%s  %s\n' "$ISO_SHA256" "$tmp" | sha256sum -c - >/dev/null || die "ISO hash mismatch"
    mv "$tmp" "$ISO"
    trap - RETURN
  fi
  [ "$(stat -c %s "$ISO")" = "$ISO_SIZE" ] || die "staged ISO size mismatch"
  printf '%s  %s\n' "$ISO_SHA256" "$ISO" | sha256sum -c - >/dev/null || die "staged ISO hash mismatch"
  printf '%s  %s\n' "$ISO_SHA256" redstar.iso >"$STAGE/MANIFEST.sha256.tmp"
  mv "$STAGE/MANIFEST.sha256.tmp" "$STAGE/MANIFEST.sha256"
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
  rm -f "$PIDFILE" "$QMP" "$HMP" "$WORK/vnc.sock"
}
trap vm_stop EXIT

vm_start() { # vga, optional cd
  local vga=$1 cd=${2:-}
  vm_stop
  local cdargs=()
  [ -z "$cd" ] || cdargs=(-drive "file=$cd,format=raw,if=ide,index=2,media=cdrom,readonly=on")
  qemu-system-x86_64 \
    -name redstar2-build -nodefaults \
    -enable-kvm -machine pc-i440fx-11.0 -cpu host \
    -m 1024 -smp 1 -rtc base=localtime \
    -drive "file=$DISK,format=qcow2,if=ide,index=0" "${cdargs[@]}" \
    -boot order="$([ -n "$cd" ] && printf d || printf c)" \
    -vga "$vga" -usb -device usb-tablet \
    -display none -vnc "unix:$WORK/vnc.sock" \
    -qmp "unix:$QMP,server=on,wait=off" \
    -monitor "unix:$HMP,server,nowait" -pidfile "$PIDFILE" \
    -daemonize -D "$WORK/qemu.log"
  for _ in $(seq 1 120); do
    [ -S "$QMP" ] && [ -S "$HMP" ] && [ -f "$PIDFILE" ] && return
    sleep 0.25
  done
  die "QEMU sockets did not appear"
}

hmp() { printf '%s\n' "$1" | socat - UNIX-CONNECT:"$HMP" >/dev/null; }
keys() {
  local key
  for key in "$@"; do
    hmp "sendkey $key"
    sleep 0.12
  done
}
# shellcheck disable=SC2086 # ${2:-} is an optional single-word flag (e.g. --no-enter); unquoted so it vanishes entirely (0 args) rather than passing an empty-string arg when omitted
type_text() { printf %s "$1" | python3 "$ASSET_DIR/qmp-secret-type.py" ${2:-} "$QMP"; }
shot() { hmp "screendump $EVIDENCE/$1.ppm"; }
ocr() { tesseract "$EVIDENCE/$1.ppm" stdout -l kor+eng 2>/dev/null | tr '\n' ' '; }
wait_ocr() { # label, regex, seconds
  local label=$1 regex=$2 limit=$3 start=$SECONDS text
  while ((SECONDS - start < limit)); do
    shot "state-$label"
    text=$(ocr "state-$label")
    if grep -Eiq "$regex" <<<"$text"; then
      log "state $label detected"
      return 0
    fi
    sleep 2
  done
  cp "$EVIDENCE/state-$label.ppm" "$FAILURES/$label-timeout.ppm" 2>/dev/null || true
  die "state $label not detected within ${limit}s"
}

make_fix_cd() {
  rm -rf "$FIX_TREE"
  mkdir -p "$FIX_TREE"
  cp "$ASSET_DIR"/{install-evdev-fix.sh,configure-guest.sh,evdev-absolute.patch} "$FIX_TREE/"
  local fc6=https://archive.fedoraproject.org/pub/archive/fedora/linux/core/6/i386/os/Fedora/RPMS
  local files=(
    binutils-2.17.50.0.3-6.i386.rpm gcc-4.1.1-30.i386.rpm
    glibc-devel-2.5-3.i386.rpm glibc-headers-2.5-3.i386.rpm pkgconfig-0.21-1.fc6.i386.rpm
  ) f
  for f in "${files[@]}"; do
    curl -fL --retry 4 -o "$FIX_TREE/$f.tmp" "$fc6/$f"
    mv "$FIX_TREE/$f.tmp" "$FIX_TREE/$f"
  done
  curl -fL --retry 4 -o "$FIX_TREE/xorg-x11-proto-devel-7.2-9.fc7.i386.rpm.tmp" \
    https://archive.fedoraproject.org/pub/archive/fedora/linux/releases/7/Everything/i386/os/Fedora/xorg-x11-proto-devel-7.2-9.fc7.i386.rpm
  mv "$FIX_TREE/xorg-x11-proto-devel-7.2-9.fc7.i386.rpm.tmp" "$FIX_TREE/xorg-x11-proto-devel-7.2-9.fc7.i386.rpm"
  curl -fL --retry 4 -o "$FIX_TREE/xorg-x11-server-sdk-1.3.0.0-17.fc7.i386.rpm.tmp" \
    https://archive.fedoraproject.org/pub/archive/fedora/linux/updates/7/i386/xorg-x11-server-sdk-1.3.0.0-17.fc7.i386.rpm
  mv "$FIX_TREE/xorg-x11-server-sdk-1.3.0.0-17.fc7.i386.rpm.tmp" "$FIX_TREE/xorg-x11-server-sdk-1.3.0.0-17.fc7.i386.rpm"
  curl -fL --retry 4 -o "$FIX_TREE/xf86-input-evdev-1.1.5.tar.bz2.tmp" \
    https://xorg.freedesktop.org/releases/individual/driver/xf86-input-evdev-1.1.5.tar.bz2
  mv "$FIX_TREE/xf86-input-evdev-1.1.5.tar.bz2.tmp" "$FIX_TREE/xf86-input-evdev-1.1.5.tar.bz2"
  genisoimage -quiet -R -J -V REDSTAR2_FIX -o "$FIX_ISO.tmp" "$FIX_TREE"
  mv "$FIX_ISO.tmp" "$FIX_ISO"
}

install_guest() {
  [ ! -e "$DISK" ] || die "fresh install refuses existing $DISK (move it aside explicitly)"
  qemu-img create -f qcow2 "$DISK.tmp" 16G >/dev/null
  mv "$DISK.tmp" "$DISK"
  vm_start std "$ISO"
  wait_ocr welcome '설치를.*환영' 300
  keys ret
  wait_ocr initdisk '초기화' 180
  keys right ret
  wait_ocr partition '설치할.*구획' 180
  keys alt-w
  wait_ocr addpart '할당.*가능' 120
  keys slash alt-a alt-p alt-o
  wait_ocr partitionmade '기본구획|primary' 120
  keys ret
  wait_ocr bootloader '기동적재기|boot.*loader' 180
  keys ret
  wait_ocr rootpass 'root|관리자.*암호|암호' 180
  type_text "$GUEST_PASSWORD" --no-enter
  keys tab
  type_text "$GUEST_PASSWORD" --no-enter
  keys ret
  wait_ocr complete '완료되였|설치.*완료|complete' 7200
  shot installer-complete
  vm_stop
}

configure_guest() {
  vm_start cirrus "$FIX_ISO"
  wait_ocr firstlogin 'root' 300
  keys ret
  type_text "$GUEST_PASSWORD"
  wait_ocr desktop '나의.*콤퓨터|휴지통|제품소개' 300
  keys alt-f2
  sleep 1
  type_text konsole
  wait_ocr terminal 'root@localhost|localhost.*#' 120
  type_text 'mkdir -p /mnt/fix'
  type_text 'mount /dev/cdrom /mnt/fix'
  type_text 'sh /mnt/fix/install-evdev-fix.sh'
  wait_ocr evdevdone 'REDSTAR2_EVDEV_FIX_INSTALLED' 900
  type_text 'sh /mnt/fix/configure-guest.sh'
  wait_ocr guestdone 'REDSTAR2_GUEST_CONFIGURED' 120
  type_text 'passwd gallery'
  sleep 1
  type_text "$GUEST_PASSWORD" --no-enter
  keys ret
  type_text "$GUEST_PASSWORD" --no-enter
  keys ret
  wait_ocr passwdone 'successfully|성공|완료' 120
  type_text sync
  vm_stop
}

seal_golden() {
  vm_start cirrus
  wait_ocr ready '나의.*콤퓨터|휴지통|제품소개' 300
  keys f5
  sleep 3
  shot ready-desktop
  vm_stop
  qemu-img convert -p -O qcow2 "$DISK" "$WORK/redstar2-pre-golden.qcow2.tmp"
  mv "$WORK/redstar2-pre-golden.qcow2.tmp" "$WORK/redstar2-pre-golden.qcow2"
  vm_start cirrus
  wait_ocr ready-after-backup '나의.*콤퓨터|휴지통|제품소개' 300
  keys f5
  sleep 3
  hmp 'savevm golden'
  qemu-img snapshot -l "$DISK" | grep -Eq '[[:space:]]golden[[:space:]]' || die "golden tag missing"
  # Dirty the desktop, restore, and require the logged-in fixture again.
  keys alt-f2
  sleep 1
  hmp 'loadvm golden'
  wait_ocr restored '나의.*콤퓨터|휴지통|제품소개' 60
  vm_stop

  mkdir -p "$OUT_DIR"
  [ ! -e "$OUT_DIR/redstar2.qcow2" ] || cp -a "$OUT_DIR/redstar2.qcow2" "$OUT_DIR/redstar2.qcow2.rollback-$(date +%Y%m%d%H%M%S)"
  qemu-img convert -p -O qcow2 "$WORK/redstar2-pre-golden.qcow2" "$OUT_DIR/redstar2.qcow2.bak-pre-golden.tmp"
  mv "$OUT_DIR/redstar2.qcow2.bak-pre-golden.tmp" "$OUT_DIR/redstar2.qcow2.bak-pre-golden"
  cp --reflink=auto "$DISK" "$OUT_DIR/redstar2.qcow2.tmp"
  mv "$OUT_DIR/redstar2.qcow2.tmp" "$OUT_DIR/redstar2.qcow2"
  qemu-img snapshot -l "$OUT_DIR/redstar2.qcow2" | grep -Eq '[[:space:]]golden[[:space:]]' || die "deployed golden tag missing"
}

stage_media
make_fix_cd
install_guest
configure_guest
seal_golden
log "PASS: $OUT_DIR/redstar2.qcow2 (golden; no guest network device in any phase)"
