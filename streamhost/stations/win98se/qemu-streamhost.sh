#!/bin/bash
# Launch tile 'win98se' (VMID 92) QEMU with the streamhost display wiring.
# GOLDEN FIXTURE tile.  Windows 98 SE is a real disk-backed guest: both IDE disks
# (win98se-kvm.qcow2 = C:, win98se-games.qcow2 = D:) are qcow2, so the live
# `savevm golden` VM-state snapshot is stored INSIDE those base qcow2 disks.
# resetMode=loadvm  (see golden.env / golden.json).
#   * Runs WITHOUT -snapshot so `savevm golden` PERSISTS into the qcow2 disks.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden), so the
#     tile comes up already at the curated fixture (screensaver/DPMS off, steady
#     caret, Notepad input-reactive surface, taskbar clock hidden). First-ever bake
#     (no snapshot yet) launches cold -- see golden-bake.sh.
#   * Reset a running fixture to golden any time: bash golden-reset.sh (QMP loadvm).
#   * KVM accel with acpi=ON + -cpu pentium3 (apic ON, default irqchip) + a usb-tablet
#     is the validated combo (baked 2026-07-12). This golden is an ACPI-HAL install, so
#     acpi=on is REQUIRED for PCI enumeration (NIC + USB + the usb-tablet); acpi=off left
#     it on the fail-safe PnP BIOS with no PCI. usb-tablet -> absolute pointer (SH_POINTER=abs).
#     No protection error under acpi=on+KVM (verified 3 cold boots). Do NOT re-add
#     acpi=off/usb=off/-apic/kernel-irqchip=off. See docs/guests/win9x.md.
#   * EXEC CHANNEL (retronet, 2026-08-20): hostfwd 127.0.0.1:57792 -> guest :7788
#     reaches C:\WARPNET.EXE, the in-guest warpd agent built -DWARP_PORT=7788, which
#     serves the 'E' exec verb (exec_kind "warpd_e"; labctl exec win98se "<cmd>").
#     It is RUNNING inside the golden and re-launches from the StartUp folder on a
#     cold boot. A hostfwd is a netdev BACKEND property, not a -device, so the
#     emulated device set is unchanged and `loadvm golden` stays valid. Do NOT
#     renumber n0. See docs/lab/retronet/EXEC-CHANNEL.md.
# Kill only by pidfile. neko is restored by ROLLBACK.md.
set -e
B=/data/vms/streamhost/stations/win98se
KVM=/data/gallery-guests/Win98SE/win98se-kvm.qcow2
GAMES=/data/gallery-guests/Win98SE/win98se-games.qcow2
[ -f "$B/qemu.pid" ] && kill "$(cat "$B/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$B/qmp.sock" "$B/qemu.pid"
# Boot straight into the fixture if the golden snapshot is already present in C:.
LOADVM=""
qemu-img snapshot -l "$KVM" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-win98se \
  -enable-kvm -m 384 -smp 1 \
  -machine pc-i440fx-11.0,acpi=on -cpu pentium3 \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -drive file="$KVM",format=qcow2,if=ide \
  -drive file="$GAMES",format=qcow2,if=ide,index=1 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:57792-:7788 -device pcnet,netdev=n0 \
  -usb -device usb-tablet,id=tab0 \
  $LOADVM \
  -qmp unix:$B/qmp.sock,server=on,wait=off \
  -pidfile $B/qemu.pid \
  >"$B/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$B/qmp.sock" ] && [ -f "$B/qemu.pid" ] && break
  sleep 0.5
done
echo "tile win98se qemu pid=$(cat $B/qemu.pid 2>/dev/null) qmp=$B/qmp.sock udp=54092 loadvm='${LOADVM:-<none: cold boot>}'"
