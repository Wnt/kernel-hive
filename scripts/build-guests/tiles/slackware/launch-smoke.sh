#!/bin/bash
# smoke launcher for slackware (Slackware 3.4, kernel 2.0.30 via -kernel, XFree86 3.3.1 on cirrus)
# usage: launch-smoke.sh [DIR] [extra qemu args...]   DIR defaults to this script's dir
set -e
RIG=${1:-$(cd "$(dirname "$0")" && pwd)}; shift || true
cd "$RIG"
[ -f qemu.pid ] && kill "$(cat qemu.pid)" 2>/dev/null || true
sleep 0.3; rm -f qmp.sock qemu.pid
[ -f disk.qcow2 ] || cp /data/vms/sandbox/slackware/build/disk.qcow2 disk.qcow2
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name "smoke-slackware-$(basename "$RIG")" \
  -enable-kvm -m 32 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0 -cpu "${SLACK_CPU:-host}" \
  -rtc base=localtime \
  -cdrom /data/assets-staging/slackware/grub-boot.iso -boot d -vga cirrus \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -chardev msmouse,id=ms0 -serial chardev:ms0 \
  -drive file="$RIG/disk.qcow2",format=qcow2,if=ide \
  ${RIG_EXTRA:-} \
  -qmp "unix:$RIG/qmp.sock,server=on,wait=off" \
  -pidfile "$RIG/qemu.pid" "$@" \
  > "$RIG/qemu.log" 2>&1 &
for i in $(seq 1 40); do [ -S "$RIG/qmp.sock" ] && [ -f "$RIG/qemu.pid" ] && break; sleep 0.5; done
echo "smoke slackware pid=$(cat "$RIG/qemu.pid" 2>/dev/null) qmp=$RIG/qmp.sock"
