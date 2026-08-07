#!/bin/bash
# Launch tile 'solariscde' (VMID 100) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
#
# GOLDEN FIXTURE MODE (resetMode=loadvm, see golden.env / golden.json):
#   * Boots the tile-LOCAL persistent golden disk solariscde-golden.qcow2 (a copy of
#     the shared gallery image /data/gallery-guests/SolarisCDE/solaris.qcow2, which is
#     left PRISTINE as the backup) with NO -snapshot, so QMP savevm/loadvm can
#     create/restore the live "golden" reset point IN this qcow2.
#   * Requires and boots STRAIGHT INTO the 'golden' snapshot (-loadvm golden), so the
#     production tile can never fall through to a cold boot. Bake only on a namespaced
#     clone with golden-bake-solaris-clone.py.
#   * NEVER delete solariscde-golden.qcow2 -- it IS the golden snapshot container.
#   * The gallery-hid VMState golden requires a QEMU carrying the gallery-hid PCI
#     device, the two-socket CPU identity, and matching driver/Xorg state baked into
#     the disk. As of 2026-07-27 that device ships in the packaged pve-qemu (quilt
#     patch pve/0049), so this tile runs the fleet /usr/bin/qemu-system-x86_64 and the
#     hand-built standalone binary is retired (its pc-bios dir is kept only for the
#     stock BIOS blobs -L points at). VMState restore on the packaged binary verified.
set -euo pipefail
D="${D:-/data/vms/streamhost/tiles/solariscde}"
DISK="${DISK:-$D/solariscde-golden.qcow2}"
QEMU="${QEMU:-/usr/bin/qemu-system-x86_64}"
QEMU_DATA="${QEMU_DATA:-/data/vms/streamhost/qemu-gallery-hid/pc-bios}"
HOSTFWD="${HOSTFWD:-57790}"
VMID="${VMID:-100}"
[ -x "$QEMU" ] || {
  echo "missing gallery-hid QEMU: $QEMU" >&2
  exit 1
}
[ -d "$QEMU_DATA" ] || {
  echo "missing QEMU data: $QEMU_DATA" >&2
  exit 1
}
[ -f "$DISK" ] || {
  echo "missing Solaris golden disk: $DISK" >&2
  exit 1
}
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden || {
  echo "refusing cold boot: golden snapshot missing from $DISK" >&2
  exit 1
}
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup "$QEMU" -L "$QEMU_DATA" \
  -name "streamhost-solariscde-vmid-$VMID" \
  -enable-kvm -m 3072 -smp 2,sockets=2,cores=1,threads=1 \
  -machine pc-i440fx-11.0 \
  -cpu Nehalem,hv-vendor-id=XenVMMXenVMM,hv-relaxed,-x2apic \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -drive file="$DISK",if=ide,index=0,media=disk,format=qcow2 \
  -loadvm golden \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$HOSTFWD"-10.0.2.15:7777 -device e1000,netdev=net0 \
  -chardev socket,id=ghid0,path="$D/gallery-hid.sock",server=on,wait=off \
  -device gallery-hid-pci,id=ghid0,chardev=ghid0,bus=pci.0,addr=0x1e \
  -no-shutdown \
  -qmp unix:"$D"/qmp.sock,server=on,wait=off \
  -pidfile "$D/qemu.pid" \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile solariscde vmid=$VMID qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54100 loadvm=golden gallery-hid=$D/gallery-hid.sock"
