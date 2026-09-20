#!/bin/bash
# Launch station 'minix2' (VMID 201) — Minix 2.0.4 (Tanenbaum), QEMU text console.
# Kill only by pidfile.
#
# GOLDEN TEST FIXTURE (2026-09-13): runs WITHOUT -snapshot (writes persist to the
# qcow2) and boots into the 'golden' live snapshot when it exists.
# resetMode=loadvm: the reset harness issues QMP `loadvm golden` to revert the
# guest to the fixture (a logged-in root shell showing `uname -a` + `ls /usr/src`).
# Without the snapshot the launcher cold-boots to the Minix boot monitor 2.19
# menu, which WAITS for a keypress ('=' Start Minix) — that is by design, it is
# how the exhibit's cold-boot arm is calibrated.
#
# DEVICE SET IS FROZEN WITH THE GOLDEN (AGENTS.md rule 6):
#   - IDE disk with EXPLICIT CHS 200/16/32 — the woodhull pre-installed image is a
#     50 MB raw with that geometry baked into its partition table; QEMU's auto
#     geometry gives a different translation and Minix's at_wini then reads garbage.
#   - -m 32 -smp 1: Minix 2.0.4 is uniprocessor and sizes its RAM disk from memory.
#   - -vga std, no NIC (retronet OPEN), no floppy (install media is not shipped).
#   - pcspk via the dbus audiodev: the Minix console bell is the only audio source.
set -e
[ -f "/data/vms/streamhost/stations/linux012/qemu.pid" ] && kill "$(cat "/data/vms/streamhost/stations/linux012/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "/data/vms/streamhost/stations/linux012/qmp.sock" "/data/vms/streamhost/stations/linux012/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms (default 4).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l /data/vms/streamhost/stations/linux012/disk.qcow2 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-linux012 \
  -enable-kvm -m 32 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0 -cpu host \
  -rtc base=localtime \
  -boot c \
  $LOADVM \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  \
  -drive file=/data/vms/streamhost/stations/linux012/disk.qcow2,format=qcow2,if=none,id=hd0 \
  -device ide-hd,drive=hd0,bus=ide.0,unit=0,cyls=200,heads=16,secs=32 \
  -qmp unix:/data/vms/streamhost/stations/linux012/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/stations/linux012/qemu.pid \
  >"/data/vms/streamhost/stations/linux012/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "/data/vms/streamhost/stations/linux012/qmp.sock" ] && [ -f "/data/vms/streamhost/stations/linux012/qemu.pid" ] && break
  sleep 0.5
done
echo "tile minix2 qemu pid=$(cat /data/vms/streamhost/stations/linux012/qemu.pid 2>/dev/null) qmp=/data/vms/streamhost/stations/linux012/qmp.sock udp=54201"
