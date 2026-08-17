#!/bin/bash
# Launch tile 'beos' (VMID 143) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# BeOS R5 Professional 5.0.3 (Be Inc., 2000) — the original behind the haiku
# station. Native x86 on the i440fx PC machine, but under TCG: the R5 kernel
# takes #GP under KVM (idle-thread trap 0d with pentium2/pentium3, a later hang
# with qemu32 — unhandled MSR reads that TCG returns 0 for). Pentium III class,
# one CPU, 512 MB (R5 caps RAM well below 1 GB). PS/2 keyboard + mouse: R5 has
# no absolute-tablet driver; the pointer is driven relative through browser
# pointer-lock (pointerRel, the qnx pattern).
# std VGA is R5's "unsupported card" VESA stub at the vesa-settings mode
# 1024x768x16; ne2k_pci is the R5 'ether' driver's card. NO audio device: both
# QEMU AC97 (R5 i801 driver) and ES1370 (es137x) stall the guest the moment the
# media_server opens them under TCG — open item in docs/guests/beos.md. See docs/guests/beos.md
# for the two blockers that had to be fixed INSIDE the volume (config_manager/isa
# removed; multiprocessor_support disabled so PCI IRQs route through the PIC).
#
# GOLDEN FIXTURE MODE (resetMode=loadvm):
#   * Boots the persistent tile-LOCAL golden qcow2 (NO -snapshot) so QMP
#     savevm/loadvm can create/restore the live "golden" reset point IN it. The
#     disk is a standalone qcow2 (no backing dep), a curated copy of the
#     installed volume which stays untouched at
#     /data/gallery-guests/Beos/beos-r5.qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden -S,
#     frozen at the fixture until the daemon resumes it). The first-ever bake
#     (no snapshot yet) launches cold.
set -e
D=/data/vms/streamhost/stations/beos
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/beos-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-beos \
  -accel tcg -m 512 -smp 1 \
  -machine pc-i440fx-11.0 -cpu pentium3 \
  -rtc base=localtime \
  -drive file=$D/beos-golden.qcow2,format=qcow2,if=ide,index=0 -boot c \
  -vga std \
  -display dbus,p2p=on \
  -netdev user,id=n0 -device ne2k_pci,netdev=n0 \
  -serial file:$D/serial.log \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile beos qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54143 loadvm='${LOADVM:-<none: cold boot>}' (golden, no -snapshot)"
