#!/bin/bash
# Launch tile 'os213' (VMID 203) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# IBM OS/2 1.30.2 Standard Edition with Presentation Manager (1991; PM debuted in
# OS/2 1.1, 1988) — the Desktop Manager shell, before the Workplace Shell of
# OS/2 2.x/Warp. Installed here from the 10-disk IBM SE floppy set onto a FAT
# hard disk; see docs/lab/OS213-WAVE.md and docs/guests/os213.md.
#
# ACCELERATOR: `-enable-kvm`, and this is THE load-bearing flag. Under
#   `-accel tcg` this guest dies at a truncated `TRAP` a moment after the boot
#   banner — reproduced on TWO independently produced OS/2 1.3 systems (this
#   Microsoft 1.30.1 image, and a complete IBM 1.30.2 SE floppy install, which
#   trapped at the installer's own first reboot). Changing ONLY the accelerator
#   fixes it: KVM reaches the PM Desktop Manager in ~20 s. Same QEMU TCG defect
#   the `xenix` station hit the same night. Do NOT "simplify" this back to TCG.
# MACHINE: `-machine isapc -cpu 486`. OS/2 1.x predates PCI entirely. QEMU
#   accepts `-enable-kvm` with `isapc` without complaint. The standard i440fx
#   machine with ACPI off, plus `-vga std`, also works under KVM (raced, theory
#   `kvmpc`) and is the fallback if isapc ever regresses. NOTE: do not spell that
#   fallback out as a literal machine string in this comment — `emit --pin-machine`
#   rewrites any machine-type literal it finds, comments included, and the
#   resulting source/emitted mismatch trips the push gate's box-state check.
# RAM: 16 MB, the size the source image was produced with.
# DISK: plain `-device ide-hd` with AUTO geometry. Do NOT pin CHS. `-drive
#   file=...,cyls=` is rejected outright by QEMU 11 ("Block format 'qcow2' does
#   not support the option 'cyls'") — geometry only goes on the ide-hd device —
#   and pinning the Microsoft image's descriptor geometry (310/16/63) made the
#   boot WORSE, not better. FAT, under the OS/2 1.3 504 MB CHS ceiling.
# DISPLAY: `-device isa-vga`; PM runs VGA 640x480x16.
# POINTER: ABSOLUTE, by writing the guest's OWN Presentation Manager pointer
#   coordinate (2026-09-13 cutover). isapc has no USB at all, so `usb-tablet`
#   is unavailable — but OS/2 1.3's PM mouse stack keeps its pointer as an
#   int16 pair in Y-THEN-X order, little-endian, y-DOWN (layout
#   `point16le_yx`) at guest-physical `0x253ca`. `-device kh-ramabs` writes
#   the commanded pixel there and injects ONE PS/2 unit to make PM republish
#   it. Needs the kh-ramabs build (OS213_QEMU, default /opt/qemu-os213) —
#   BINARY AND GOLDEN ARE ONE UNIT: the golden is baked under that binary and
#   the ADDRESS IS BOUND TO THE GOLDEN (re-bake => re-derive with
#   docs/guests/os213.md §Pointer's re-derive recipe). FAIL CLOSED: no
#   KH_RAMABS_ADDR => no device and the relative path; a stale address is
#   refused by the device's connect-time write probe instead of corrupting
#   guest memory. SINGLE INJECTOR: while ptr.sock is connected nothing else —
#   no QMP input-send-event, no labctl pointer helper — may push motion or a
#   button edge at this mouse. The 2:1 mickey ratio (docs/guests/os213.md
#   §The 2:1 mickey ratio) is why a rescaled relative pointer could never be
#   1:1 here; kh-ramabs sidesteps it entirely by writing the position, not
#   dead-reckoning it.
# NETWORK: NONE. OS/2 1.3 has no bundled TCP/IP stack (IBM TCP/IP for OS/2 1.3
#   was a separate product), so this station is NOT on the retronet and has no
#   rn-tapnet.sh (rule 15 — never commit a tap script for an unproven station).
#
# GOLDEN FIXTURE MODE (resetMode=loadvm, see GOLDEN.md):
#   * The disk is staged by station-land.sh as $D/disk.qcow2 — that name is the
#     fleet convention the landing script parks and restores (disk.qcow2.pre-*).
#     Do NOT rename it to <id>-golden.qcow2: the nt351 sibling this launcher was
#     scaffolded from predates that convention, and the mismatch cost os213 a
#     failed station-up (29 restart attempts, "Could not open ...").
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
qemu-img snapshot -l "$D/disk.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
PTR_ARGS=()
if [ -n "${KH_RAMABS_ADDR:-}" ]; then
  rm -f "$D/ptr.sock"
  PTR_ARGS=(
    -chardev "socket,id=ptr0,path=$D/ptr.sock,server=on,wait=off"
    -device "kh-ramabs,chardev=ptr0,addr=$KH_RAMABS_ADDR,layout=point16le_yx,width=640,height=480,nudge-units=1,nudge-px=1,trace=${PTR_TRACE:-off}"
  )
fi
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup "${OS213_QEMU:-/opt/qemu-os213/bin/qemu-system-x86_64}" \
  -name streamhost-os213 \
  -enable-kvm -m 16 -smp 1 \
  -machine isapc -cpu 486 \
  -rtc base=localtime \
  -boot c \
  -device isa-vga \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -drive file=$D/disk.qcow2,format=qcow2,if=none,id=hd0 \
  -device ide-hd,drive=hd0,bus=ide.0,unit=0 \
  $LOADVM \
  "${PTR_ARGS[@]}" \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile os213 qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54203 loadvm='${LOADVM:-<none: cold boot>}' (golden, no -snapshot)"
