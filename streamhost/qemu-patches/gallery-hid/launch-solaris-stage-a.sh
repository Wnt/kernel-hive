#!/bin/bash
# Launch an isolated Solaris gallery-hid clone.  LOADVM=golden selects the
# process-start restore proof; the default remains a cold boot for baking.
set -euo pipefail

D="${D:-/data/vms/sandbox/lli/spike-solaris-a}"
QEMU="${QEMU:-$D/qemu-build/qemu-system-x86_64}"
QEMU_DATA="${QEMU_DATA:-$D/qemu-build/pc-bios}"
DISK="${DISK:-$D/solariscde-stage-a.qcow2}"
HOSTFWD="${HOSTFWD:-58790}"
VNC_DISPLAY="${VNC_DISPLAY:-91}"
VMID="${VMID:-9910}"
LOADVM="${LOADVM:-}"
LOADVM_ARGS=()

if [ -n "$LOADVM" ]; then
  LOADVM_ARGS=(-loadvm "$LOADVM")
fi

[ -x "$QEMU" ] || {
  echo "missing scratch QEMU: $QEMU" >&2
  exit 1
}
[ -d "$QEMU_DATA" ] || {
  echo "missing QEMU data: $QEMU_DATA" >&2
  exit 1
}
[ -f "$DISK" ] || {
  echo "missing clone disk: $DISK" >&2
  exit 1
}
if [ -f "$D/qemu.pid" ]; then
  oldpid="$(cat "$D/qemu.pid")"
  if kill -0 "$oldpid" 2>/dev/null; then
    kill "$oldpid"
    for _ in $(seq 1 40); do
      kill -0 "$oldpid" 2>/dev/null || break
      sleep 0.25
    done
  fi
fi
rm -f "$D/qmp.sock" "$D/gallery-hid.sock" "$D/qemu.pid"

export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup "$QEMU" -L "$QEMU_DATA" \
  -name "gallery-lli-solaris-stage-a-vmid-$VMID" \
  -enable-kvm -m 3072 -smp 2,sockets=2,cores=1,threads=1 \
  -machine pc-i440fx-11.0 \
  -cpu Nehalem,hv-vendor-id=XenVMMXenVMM,hv-relaxed,-x2apic \
  -rtc base=localtime -boot c \
  -vga std \
  -display "vnc=127.0.0.1:$VNC_DISPLAY,audiodev=snd0" \
  -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -drive "file=$DISK,if=ide,index=0,media=disk,format=qcow2" \
  "${LOADVM_ARGS[@]}" \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$HOSTFWD-10.0.2.15:7777" \
  -device e1000,netdev=net0 \
  -chardev "socket,id=ghid0,path=$D/gallery-hid.sock,server=on,wait=off" \
  -device gallery-hid-pci,id=ghid0,chardev=ghid0,bus=pci.0,addr=0x1e \
  -no-shutdown \
  -qmp "unix:$D/qmp.sock,server=on,wait=off" \
  -pidfile "$D/qemu.pid" \
  >"$D/qemu.log" 2>&1 &

for _ in $(seq 1 60); do
  [ -S "$D/qmp.sock" ] && [ -S "$D/gallery-hid.sock" ] &&
    [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
[ -S "$D/qmp.sock" ] && [ -S "$D/gallery-hid.sock" ] &&
  [ -f "$D/qemu.pid" ] || {
  tail -80 "$D/qemu.log" >&2
  exit 1
}
echo "vmid=$VMID pid=$(cat "$D/qemu.pid") qmp=$D/qmp.sock vnc=127.0.0.1:$((5900 + VNC_DISPLAY)) hostfwd=$HOSTFWD loadvm=${LOADVM:-none}"
