#!/bin/bash
# Launch tile 'xenix' (VMID 202) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# SCO Xenix System V/386 2.3.4 (1989) — Microsoft's Unix, text console with
# Multiscreen (Alt-F1..Alt-F4). Device set is deliberately 1989-era:
#   -machine isapc   no PCI at all; Xenix 2.3.4 predates PCI and its IDE/console
#                    drivers probe the ISA/AT hardware only.
#   -cpu 486         Xenix 386 dislikes CPUID/Pentium+ feature bits.
#   TCG, no KVM      386-era protected-mode code has bitten KVM before; TCG is
#                    the safe default and 16 MB of 486 is not a performance
#                    problem for a text console.
#   explicit CHS     the disk MUST be <= 504 MB and carry the geometry the
#                    installer saw, or the Xenix boot block reads garbage.
#   -vga std         ISA VGA; the guest is text mode (80x25) the whole time.
# No NIC: SCO TCP/IP for Xenix is a separate product — retronet is OPEN.
#
# GOLDEN TEST FIXTURE: runs WITHOUT -snapshot (writes persist to the qcow2) and
# boots into the 'golden' live snapshot when it exists. resetMode=loadvm: the
# reset harness issues QMP `loadvm golden` to revert the guest to a logged-in
# root shell. Without a snapshot the launcher cold-boots to the Xenix boot
# prompt so a fresh build can be calibrated and baked.
set -e
[ -f "/data/vms/streamhost/stations/xenix/qemu.pid" ] && kill "$(cat "/data/vms/streamhost/stations/xenix/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "/data/vms/streamhost/stations/xenix/qmp.sock" "/data/vms/streamhost/stations/xenix/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms (default 4).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l /data/gallery-guests/Xenix/xenix.qcow2 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-i386 \
  -name streamhost-xenix \
  -m 16 \
  -machine isapc -cpu 486 \
  -rtc base=localtime \
  -boot c \
  $LOADVM \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  \
  -drive file=/data/gallery-guests/Xenix/xenix.qcow2,format=qcow2,if=ide,index=0,media=disk,cyls=1000,heads=16,secs=63 \
  -qmp unix:/data/vms/streamhost/stations/xenix/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/stations/xenix/qemu.pid \
  >"/data/vms/streamhost/stations/xenix/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "/data/vms/streamhost/stations/xenix/qmp.sock" ] && [ -f "/data/vms/streamhost/stations/xenix/qemu.pid" ] && break
  sleep 0.5
done
echo "tile xenix qemu pid=$(cat /data/vms/streamhost/stations/xenix/qemu.pid 2>/dev/null) qmp=/data/vms/streamhost/stations/xenix/qmp.sock udp=54202"
