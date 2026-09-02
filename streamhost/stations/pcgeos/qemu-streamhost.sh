#!/bin/bash
# Launch station 'pcgeos' (VMID 175) QEMU with the streamhost display wiring.
# PC/GEOS Ensemble (bluewaysw CI build, Apache-2.0) on FreeDOS 1.3.
#   * disk.qcow2 is the ONLY block device: FreeDOS FAT16 + C:\ENSEMBLE, and it
#     carries the savevm 'golden' vmstate, so loadvm restores the filesystem too.
#     Copied from the builder output on first launch; NEVER delete or replace it —
#     recapture only via `checkpoint-guard recapture pcgeos`.
#   * Runs WITHOUT -snapshot; boots straight into 'golden' when it exists,
#     otherwise cold-boots FreeDOS -> FDAUTO.BAT -> C:\ENSEMBLE\loader.exe.
#   * -vga std: GEOS uses its VESA driver (vga16.geo) at 800x600 16-bit.
#   * sb16 + PC speaker -> dbus audiodev; PS/2 relative pointer (CTMOUSE + genmouse.geo).
# Kill only by pidfile.
set -e
BASE=/data/vms/streamhost/stations/pcgeos
DISK="$BASE/disk.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
[ -f "$DISK" ] || cp /data/gallery-guests/PCGEOS/pcgeos.qcow2 "$DISK"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms (default 4).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-pcgeos \
  -enable-kvm -m 64 -smp 2 \
  -machine pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0 -cpu host \
  -rtc base=localtime \
  -boot c \
  $LOADVM \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  \
  -drive file=/data/vms/streamhost/stations/pcgeos/disk.qcow2,format=qcow2,if=ide -netdev user,id=n0 -device ne2k_pci,netdev=n0 \
  -qmp unix:/data/vms/streamhost/stations/pcgeos/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/stations/pcgeos/qemu.pid \
  >"/data/vms/streamhost/stations/pcgeos/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "station pcgeos qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54175 loadvm='${LOADVM:-<none: cold boot>}'"
