#!/usr/bin/env bash
# Launch an isolated NT4 Cirrus candidate. Never use this for a production tile.
set -euo pipefail

readonly PATCHED_QEMU=${PATCHED_QEMU:-/data/vms/soltest/cvmstate-trace-20260728T084646Z-14233/qemu-fixed-clean}

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 2 && $# -le 3 ]] ||
  die "usage: $0 <nt4-cirrus-clone-dir> <A|A-ISA|A-ISA-TCG|B> [cold|golden]"
D=${1%/}
option=$2
start=${3:-cold}
disk=$D/nt4-candidate.qcow2

case "$D/" in
  /data/vms/soltest/nt4-cirrus-*/*) ;;
  *) die "refusing non-NT4-Cirrus clone path: $D" ;;
esac
case "$option:$start" in
  A:cold | A:golden | A-ISA:cold | A-ISA:golden | \
    A-ISA-TCG:cold | A-ISA-TCG:golden | B:cold | B:golden) ;;
  *) die "option/start must be A|A-ISA|A-ISA-TCG|B and cold|golden" ;;
esac

# shellcheck source=/dev/null
source /usr/local/bin/clone-guard
clone-guard assert-path "$D"
clone-guard assert-qmp "$D/qmp.sock"
[[ -x "$PATCHED_QEMU" ]] || die "missing patched QEMU: $PATCHED_QEMU"
[[ -f "$disk" ]] || die "missing clone disk: $disk"

if [[ -f "$D/qemu.pid" ]]; then
  clone-guard kill-pidfile "$D/qemu.pid"
fi
rm -f "$D/qmp.sock" "$D/qemu.pid"

case "$option" in
  A)
    machine_args=(-enable-kvm -machine pc-i440fx-11.0,hpet=off,vmport=on -cpu pentium3)
    display_device=(-device cirrus-vga)
    disk_device=(-drive file="$disk",format=qcow2,if=ide)
    network_device=(-netdev user,id=n0 -device pcnet,netdev=n0)
    ;;
  A-ISA)
    machine_args=(-enable-kvm -machine pc-i440fx-11.0,hpet=off,vmport=on -cpu pentium3)
    display_device=(-device isa-cirrus-vga,global-vmstate=on)
    disk_device=(-drive file="$disk",format=qcow2,if=ide)
    network_device=(-netdev user,id=n0 -device pcnet,netdev=n0)
    ;;
  A-ISA-TCG)
    machine_args=(-accel tcg -machine pc-i440fx-11.0,hpet=off,vmport=on -cpu pentium3)
    display_device=(-device isa-cirrus-vga,global-vmstate=on)
    disk_device=(-drive file="$disk",format=qcow2,if=ide)
    network_device=(-netdev user,id=n0 -device pcnet,netdev=n0)
    ;;
  B)
    machine_args=(-accel tcg -machine isapc -cpu pentium)
    display_device=(-device isa-cirrus-vga,global-vmstate=on)
    # The preserved 8 GiB VMware image has an NTFS BPB and MBR geometry of
    # 255 heads / 63 sectors. isapc otherwise advertises a legacy 16-head
    # geometry, so NT's boot loader and atapi.sys disagree and STOP 0x7B.
    disk_device=(
      -drive file="$disk",format=qcow2,if=none,id=disk0
      -device
      ide-hd,drive=disk0,bus=ide.0,cyls=16383,heads=16,secs=63,lcyls=1044,lheads=255,lsecs=63,bios-chs-trans=lba
    )
    network_device=()
    ;;
esac
loadvm_args=()
[[ "$start" == cold ]] || loadvm_args=(-loadvm golden)

nohup "$PATCHED_QEMU" -L /usr/share/kvm \
  -name "nt4-cirrus-option-$option" \
  "${machine_args[@]}" -m 128 -smp 1 \
  -rtc base=localtime \
  "${display_device[@]}" \
  "${disk_device[@]}" \
  "${network_device[@]}" \
  -display none \
  "${loadvm_args[@]}" \
  -qmp unix:"$D/qmp.sock",server=on,wait=off \
  -pidfile "$D/qemu.pid" \
  >"$D/qemu.log" 2>&1 &

for _ in $(seq 1 40); do
  [[ -S "$D/qmp.sock" && -f "$D/qemu.pid" ]] && break
  sleep 0.5
done
[[ -S "$D/qmp.sock" && -f "$D/qemu.pid" ]] ||
  die "QEMU did not create its guarded pidfile and QMP socket"
printf 'clone=%s option=%s start=%s pid=%s qmp=%s\n' \
  "$D" "$option" "$start" "$(<"$D/qemu.pid")" "$D/qmp.sock"
