#!/bin/bash
# Launch tile 'nt351' (VMID 83) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# Windows NT 3.51 Workstation — the last Program-Manager-shell NT. Native x86,
# but on the legacy ISA machine: NT 3.51's HAL predates PCI plug-and-play, so it
# wants an ISA PC with a 486-class CPU and an NE2000-ISA NIC. `-M isapc` is
# REQUIRED (a PCI i440fx machine bluescreens the 3.51 kernel); isapc has no KVM
# path, so this tile runs under TCG (fine — NT 3.51 is tiny). No USB on isapc, so
# the pointer is PS/2 relative and reaches 1:1 via the cursor_scale calibration
# baked in at golden time (Stage 2, see docs/guests/nt351.md).
#
# DISPLAY / MAINTENANCE: NT uses its accelerated Cirrus driver at
# 1024x768x16bpp. This tile therefore pins the dedicated QEMU build carrying
# streamhost/qemu-patches/0004-cirrus-blt-rop1-fill.patch. Rebuild that binary
# under /opt/qemu-cirrusfix whenever the packaged QEMU version changes.
#
# GOLDEN FIXTURE MODE (resetMode=loadvm, see GOLDEN.md):
#   * Boots the persistent tile-LOCAL golden qcow2 (NO -snapshot) so QMP
#     savevm/loadvm can create/restore the live "golden" reset point IN it. The
#     disk is a standalone qcow2 (no backing dep), a curated copy of the pristine
#     gallery image which stays untouched at
#     /data/gallery-guests/Nt351/nt351.qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden) so
#     the tile comes up already at the curated Program Manager fixture. The
#     first-ever bake (no snapshot yet) launches cold -- see golden-bake.sh.
set -e
D=/data/vms/streamhost/tiles/nt351
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/nt351-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup /opt/qemu-cirrusfix/bin/qemu-system-i386 \
  -L /usr/share/kvm \
  -name streamhost-nt351 \
  -accel tcg -m 64 -smp 1 \
  -machine isapc -cpu 486 \
  -rtc base=localtime \
  -cdrom /data/gallery-guests/Nt351/NTWKS351_UPD.iso -boot order=c,menu=off \
  -device isa-cirrus-vga,global-vmstate=on \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -drive file=$D/nt351-golden.qcow2,format=qcow2,if=ide -net nic,model=ne2k_isa -net user \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile nt351 qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54083 loadvm='${LOADVM:-<none: cold boot>}' (golden, no -snapshot)"
