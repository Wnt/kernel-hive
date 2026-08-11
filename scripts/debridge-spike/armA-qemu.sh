#!/bin/bash
# De-bridging spike ARM A (tier 2): the MAME Atari ST binary inside the shared
# Debian trixie bridge kiosk, captured the ordinary way (QEMU dbus display).
#
# NOT A TILE. A namespaced clone under /data/vms/soltest/ — its own overlay,
# qmp.sock, pidfile and ssh port. The LIVE `atarist` station (hatari) is arm C and
# is never touched by anything here.
#
# Device set is the live atarist station's, verbatim, so the only difference
# between this and a production kiosk is which emulator the kiosk runs.
# Kill ONLY via `clone-guard kill-pidfile`.
set -e
D=/data/vms/soltest/debridge-7f3a/armA
rm -f "$D/qmp.sock" "$D/qemu.pid"
nohup qemu-system-x86_64 \
  -name debridge-7f3a-armA \
  -enable-kvm -m 1536 -smp 2 -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -drive file="$D/overlay.qcow2",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5793-:22 -device e1000,netdev=n0 \
  -qmp unix:"$D/qmp.sock",server=on,wait=off \
  -pidfile "$D/qemu.pid" \
  >"$D/qemu.log" 2>&1 &
for _ in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "armA qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock ssh=127.0.0.1:5793"
