#!/bin/bash
# Cold-independent Solaris A/B tile using the production in-guest warpd path.
# VMID label 9911; UDP 54911; hostfwd 127.0.0.1:58791 -> guest :7777.
set -euo pipefail

D=/data/vms/streamhost/stations/soltest-warpd
DISK="$D/soltest-warpd.qcow2"
PIDFILE="$D/qemu.pid"

if [ -f "$PIDFILE" ]; then
  oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    kill "$oldpid"
    for _ in $(seq 1 40); do
      kill -0 "$oldpid" 2>/dev/null || break
      sleep 0.25
    done
  fi
fi
rm -f "$D/qmp.sock" "$PIDFILE"

LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-soltest-warpd-vmid-9911 \
  -enable-kvm -m 3072 -smp 2 \
  -machine pc-i440fx-11.0 -cpu Nehalem \
  -rtc base=localtime -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -drive file="$DISK",if=ide,index=0,media=disk,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:58791-10.0.2.15:7777 \
  -device e1000,netdev=net0 \
  -no-shutdown $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile "$PIDFILE" \
  >"$D/qemu.log" 2>&1 &

for _ in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$PIDFILE" ] && break
  sleep 0.5
done
[ -S "$D/qmp.sock" ] && [ -f "$PIDFILE" ] || {
  tail -80 "$D/qemu.log" >&2
  exit 1
}
echo "tile=soltest-warpd vmid=9911 pid=$(cat "$PIDFILE") qmp=$D/qmp.sock udp=54911 hostfwd=58791 vnc=none loadvm=${LOADVM:-cold}"
