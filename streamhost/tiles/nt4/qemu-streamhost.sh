#!/bin/bash
# Launch tile 'nt4' (VMID 89) QEMU with the streamhost display wiring.
# Windows NT 4.0 Workstation SP6a — native x86, KVM-fast, no bridge.
# Kill only by pidfile.
#
# GOLDEN FIXTURE MODE (resetMode=loadvm, see GOLDEN.md):
#   * Boots the persistent tile-LOCAL golden qcow2 (NO -snapshot) so QMP
#     savevm/loadvm can create/restore the live "golden" reset point IN it. The
#     disk is a standalone qcow2 (no backing dep), a curated copy of the
#     gallery image which stays untouched at /data/gallery-guests/Nt4/nt4-golden.qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden) so
#     the tile comes up already at the curated fixture. First-ever bake (no
#     snapshot yet) launches cold at the NT4 desktop -- see golden-bake.sh.
#
# DISPLAY / MAINTENANCE:
#   NT uses its SP6a Cirrus driver at 1024x768x16bpp. This tile pins the
#   dedicated QEMU build carrying both:
#     streamhost/qemu-patches/0004-cirrus-blt-rop1-fill.patch
#     streamhost/qemu-patches/0005-cirrus-isa-vmstate-descend-substruct.patch
#   Patch 0004 fixes accelerated fills during scroll/window redraw. Patch 0005
#   makes fresh-process -loadvm golden restore the ISA Cirrus substructure
#   correctly. Rebuild and reverify /opt/qemu-cirrusfix2 whenever the packaged
#   QEMU version changes. /opt/qemu-cirrusfix is intentionally reserved for
#   nt351 and must not be changed as part of NT4 maintenance.
#
# HARD DEVICE-SET GOTCHAS (NT4, from catalog §4 + first-light 2026-07-27):
#   * -cpu pentium3          : the HOST cpu model BSODs NT4 setup/boot. NT4
#                              predates modern CPUID leaves; pentium3 is the
#                              newest model NT4 tolerates.
#   * -smp 1                 : NT4 was installed with the UNIPROCESSOR HAL.
#                              Booting SMP with a UP HAL -> STOP 0x0000003E / hang.
#   * -machine pc-...,hpet=off: HPET confuses NT4's HAL timer setup.
#   * vmport=on             : QEMU 11 auto-instantiates its vmmouse on i8042.
#                              The preserved NT4 VMware vmmouse.sys driver
#                              consumes it as true absolute 1:1 input. Adding a
#                              second explicit -device vmmouse is invalid
#                              ('i8042 link is not set') on this QEMU version.
#   * isa-cirrus-vga         : the SP6a Cirrus driver provides accelerated
#                              1024x768x65536-color output. global-vmstate=on
#                              is part of the saved golden device contract.
#   * -device pcnet          : pinned Stage-1 NIC device. The archive's AMDPCN
#                              driver does not bind under this QEMU recipe and
#                              is disabled in the golden; the tile needs no
#                              in-guest network.
#   * boot.ini ARC path      : the prebuilt image was made on a BusLogic SCSI
#                              controller (scsi(0)... + ntbootdd.sys). The golden
#                              qcow2 has it rewritten to multi(0)... so NTLDR
#                              reads this IDE disk via INT13h. See docs/guests/nt4.md.
set -e
D=/data/vms/streamhost/tiles/nt4
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=()
LOADVM_LABEL="<none: cold boot>"
if qemu-img snapshot -l "$D/nt4-golden.qcow2" 2>/dev/null | grep -qw golden; then
  LOADVM=(-loadvm golden)
  LOADVM_LABEL="-loadvm golden"
fi
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup /opt/qemu-cirrusfix2/bin/qemu-system-i386 \
  -L /usr/share/kvm \
  -name streamhost-nt4 \
  -enable-kvm -m 128 -smp 1 \
  -machine pc-i440fx-11.0,hpet=off,vmport=on -cpu pentium3 \
  -rtc base=localtime \
  -device isa-cirrus-vga,global-vmstate=on \
  -drive file=$D/nt4-golden.qcow2,format=qcow2,if=ide \
  -netdev user,id=n0 -device pcnet,netdev=n0 \
  -display dbus,p2p=on \
  "${LOADVM[@]}" \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile nt4 qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54089 loadvm='$LOADVM_LABEL' (golden, no -snapshot)"
