#!/bin/bash
# Launch tile 'win95' (VMID 91) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
#
# GOLDEN FIXTURE MODE (resetMode=loadvm, see GOLDEN.md / golden.env / golden.json):
#   * Boots the tile-LOCAL persistent golden disk win95-golden.qcow2 (a copy of the
#     shared gallery image /data/gallery-guests/Win95/win95-osr2-kvm.qcow2, which is
#     left PRISTINE as the backup) with NO -snapshot, so QMP savevm/loadvm can
#     create/restore the live "golden" reset point IN this qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden), so the
#     tile comes up already at the curated fixture (Notepad open+maximized+focused,
#     steady non-blinking caret, screensaver off, taskbar clock hidden, no idle anim).
#     First-ever bake (no snapshot yet) launches cold -- see golden-bake.sh.
#   * NEVER delete win95-golden.qcow2 -- it IS the golden snapshot container.
#   * Wiring is IDENTICAL to the pre-golden pilot launcher (KVM, pc,acpi=off,usb=off,
#     kernel-irqchip=off, cpu pentium,-apic, vga std, sb16 audio, pcnet user-net,
#     PS/2 relative kbd+mouse) so the snapshot is portable and the transport is
#     unchanged. Only the disk (local golden, no -snapshot) differs.
set -e
D=/data/vms/streamhost/tiles/win95
DISK="$D/win95-golden.qcow2"
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-win95 \
  -enable-kvm -m 256 -smp 1 \
  -machine pc,acpi=off,usb=off,kernel-irqchip=off,accel=kvm -cpu pentium,-apic \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -drive file="$DISK",format=qcow2,if=ide -netdev user,id=n0,hostfwd=tcp:127.0.0.1:57791-:7777 -device pcnet,netdev=n0 \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile win95 qemu pid=$(cat $D/qemu.pid 2>/dev/null) qmp=$D/qmp.sock udp=54091 loadvm='${LOADVM:-<none: cold boot>}' (golden, no -snapshot)"
