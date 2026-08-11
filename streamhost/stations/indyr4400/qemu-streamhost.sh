#!/bin/bash
# Launch tile 'indyr4400' (VMID 239) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-12 kiosk running Iris (techomancer/iris, BSD-3),
# a userspace emulator of a real SGI Indy — MIPS **R4400**, 256 MB, XL/REX3
# graphics — booting IRIX 6.5.22 to the Indigo Magic login. See
# scripts/build-guests/tiles/indyr4400.sh and streamhost/docs/BRIDGE.md.
#
# DISTINCT from the 'irix' tile. That one is the same museum machine in MAME's
# indy_4610 driver (an **R4600** Indy) and runs BARE-METAL as an x11-runtime
# tile, because MAME's Indy emulation kernel-panics under a KVM vCPU. Iris is
# pure userspace Rust and has no such constraint, so this exhibit is an ordinary
# KVM bridge tile and gets pointer + keyboard + `loadvm golden` for free.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like amiga/c64/alpine). overlay.qcow2
# holds an INTERNAL 'golden' snapshot (full RAM + device state) of IRIX already
# sitting at its graphical login.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Debian boot, no X start, no ~4-minute IRIX boot, no keys.
#   * overlay.qcow2 is a THIN qcow2 OVERLAY on the read-only shared base
#     /data/vms/bridge/bridge-base.qcow2 — NEVER delete/recreate it (the golden
#     snapshot lives inside it). Runs WITHOUT -snapshot so savevm persists.
#   * The SECOND drive is the 6.3 GB IRIX disk asset, attached READ-ONLY over
#     virtio (staged by tiles/indyr4400/fetch-assets.sh). Read-only means savevm
#     ignores it, so the golden stays small and the asset can never be dirtied.
#     It is virtio and not IDE because QEMU has no read-only IDE hard disk.
#   * Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * `vmport=off`: with QEMU's VMware backdoor present, Linux's psmouse driver
#     negotiates the VMMouse ABSOLUTE protocol, and with no absolute host device
#     the relative PS/2 packets are then delivered to the kernel (IRQ12 counts up)
#     but never move the X pointer. Measured on this tile 2026-08-10.
#   * PS/2 relative pointer (no usb-tablet): Iris grabs the pointer inside its
#     window and feeds the emulated Indy PS/2 deltas, so the browser drives this
#     tile through Pointer Lock (spa pointerRel), like the qnx tile.
set -e
BASE=/data/vms/streamhost/stations/indyr4400
OVERLAY="$BASE/overlay.qcow2"
IRIXDISK="${IRISINDY_ASSET:-/data/gallery-guests/IrisIndy/irix65-r4400-disk.ext4}"
[ -f "$IRIXDISK" ] || {
  echo "missing IRIX disk asset: $IRIXDISK (run $BASE/fetch-assets.sh)" >&2
  exit 1
}
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# Boot straight into the golden IRIX-login fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-indyr4400 \
  -enable-kvm -m 2048 -smp 4 -machine pc-i440fx-11.0,vmport=off -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -drive file="$IRIXDISK",if=virtio,format=raw,readonly=on \
  -vga std \
  -display dbus,p2p=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5839-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile indyr4400 qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54136 ssh=127.0.0.1:5839 loadvm='${LOADVM:-<none: cold boot>}'"
