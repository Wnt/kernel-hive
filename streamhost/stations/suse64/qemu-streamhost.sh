#!/bin/bash
# suse64 — SuSE Linux 6.4 (2000) i386, KDE 1.1.2 on XFree86 3.3.6 (SVGA server on
# the emulated Cirrus GD5446). VERBATIM launcher, emitted into stations-manifest.sh.
# KVM. The guest runs the UP kernel (k_deflt 2.2.14) with `hdparm -d1` from boot.local, so
# PIIX bus-master DMA is on (using_dma = 1); YaST2's default k_smp loses every IDE/keyboard
# interrupt on this machine type (noapic works around it but stays PIO). The INSTALL ran under
# TCG because the 2.2 IDE PIO path is a KVM exit per outw (70 KiB/s); docs/lab/SUSE64-WAVE.md.
# Reset = `-loadvm golden` on disk.qcow2, the ONLY block device (rule 6: golden +
# /opt/qemu-beos binary + this device set are one combination — recapture through
# checkpoint-guard, never by hand). Pointer: motion is absolute through the guest's
# X server (x11warp) over the loopback SLIRP forward 6080 -> 10.0.2.15:6000; the
# golden carries `xhost +10.0.2.2`. Buttons and keys go the D-Bus PS/2 path.
set -e
BASE=/data/vms/streamhost/stations/suse64
DISK="$BASE/disk.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
[ -f "$DISK" ] || cp /data/gallery-guests/SUSE64/suse64.qcow2 "$DISK"
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
X_PORT=6080
# shellcheck disable=SC2086 # $LOADVM must word-split into flags
nohup "${SUSE64_QEMU:-/opt/qemu-beos/bin/qemu-system-x86_64}" \
  -name streamhost-suse64 \
  -enable-kvm -m 256 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off -cpu host \
  -rtc base=localtime \
  -boot c \
  $LOADVM \
  -vga cirrus \
  -display dbus,p2p=on \
  -drive file=/data/vms/streamhost/stations/suse64/disk.qcow2,format=qcow2,if=ide \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${X_PORT}-10.0.2.15:6000 -device ne2k_pci,netdev=n0 \
  -qmp unix:/data/vms/streamhost/stations/suse64/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/stations/suse64/qemu.pid \
  >"/data/vms/streamhost/stations/suse64/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile suse64 qemu pid=$(cat "$BASE/qemu.pid" 2>/dev/null) qmp=$BASE/qmp.sock udp=54180 loadvm='${LOADVM:-<none: cold boot>}'"
