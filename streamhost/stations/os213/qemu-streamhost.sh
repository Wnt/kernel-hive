#!/bin/bash
# Launch tile 'os213' (VMID 203) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# IBM OS/2 1.30.2 Standard Edition with Presentation Manager (1991; PM debuted in
# OS/2 1.1, 1988) — the Desktop Manager shell, before the Workplace Shell of
# OS/2 2.x/Warp. Installed here from the 10-disk IBM SE floppy set onto a FAT
# hard disk; see docs/lab/OS213-WAVE.md and docs/guests/os213.md.
#
# MACHINE: `-machine isapc -cpu 486`, TCG. OS/2 1.x predates PCI entirely, and
#   `-machine pc-i440fx-11.0` freezes this guest at SeaBIOS's "Booting from Hard
#   Disk..." (raced 2026-09-13, theory `pcimachine`). isapc has no KVM path, so
#   this station runs under TCG — fine, OS/2 1.3 is tiny.
# RAM: 16 MB. OS/2 1.x panics above ~16-32 MB in some builds, and `-m 8` also
#   froze at SeaBIOS in the race (theory `ramsize`).
# DISK: plain `-device ide-hd` with AUTO geometry. Do NOT pin CHS. `-drive
#   file=...,cyls=` is rejected outright by QEMU 11 ("Block format 'qcow2' does
#   not support the option 'cyls'") — geometry only goes on the ide-hd device —
#   and pinning the Microsoft image's descriptor geometry (310/16/63) made the
#   boot WORSE, not better. FAT, under the OS/2 1.3 504 MB CHS ceiling.
# DISPLAY: `-device isa-vga`; PM runs VGA 640x480x16.
# POINTER: QEMU PS/2 RELATIVE (`qemu-ps2-relative`, the freedos/nt351 pattern).
#   isapc has no USB at all, so `usb-tablet` — and with it any absolute route —
#   is unavailable. OS/2 1.3 ships the PS/2 mouse driver and uses it.
# NETWORK: NONE. OS/2 1.3 has no bundled TCP/IP stack (IBM TCP/IP for OS/2 1.3
#   was a separate product), so this station is NOT on the retronet and has no
#   rn-tapnet.sh (rule 15 — never commit a tap script for an unproven station).
#
# GOLDEN FIXTURE MODE (resetMode=loadvm, see GOLDEN.md):
#   * Boots the persistent station-LOCAL golden qcow2 (NO -snapshot) so QMP
#     savevm/loadvm can create and restore the live "golden" reset point IN it.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden) so
#     the station comes up already at the PM Desktop Manager fixture. The
#     first-ever bake (no snapshot yet) launches cold.
set -e
D=/data/vms/streamhost/stations/os213
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/os213-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-i386 \
  -name streamhost-os213 \
  -accel tcg -m 16 -smp 1 \
  -machine isapc -cpu 486 \
  -rtc base=localtime \
  -boot c \
  -device isa-vga \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -drive file=$D/os213-golden.qcow2,format=qcow2,if=none,id=hd0 \
  -device ide-hd,drive=hd0,bus=ide.0,unit=0 \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile os213 qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54203 loadvm='${LOADVM:-<none: cold boot>}' (golden, no -snapshot)"
