#!/bin/bash
# Launch station 'macosx' (slot 218) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# Mac OS X 10.3 Panther on a PowerPC G4 "mac99" — the museum's first Mac OS X
# station, and the far end of the NeXTSTEP -> Rhapsody -> Mac OS X lineage it
# already exhibits.
#
# THE BINARY IS NOT pve-qemu. The fleet package ships no ppc target, so this
# station runs the standalone kernel-hive QEMU fork at /opt/qemu-ppc (the
# macos9/macos753 arrangement; QEMU 11.0.2, fork commit carrying the cpu/tb_env
# vmstate patch that macos9's launcher documents). That patch is REQUIRED here
# too: a PowerPC checkpoint restored by a pre-patch binary resumes with the
# softmmu timebase jumped forward, and a Mach/BSD guest is no kinder about that
# than Mac OS 9's nanokernel. After any binary change, re-bake the golden cold.
#
# RELEASE CHOICE, MEASURED (2026-09-20). Mac OS X 10.2 Jaguar (Darwin 6.0) was
# the first target and it PANICS on this machine, reproducibly, ~50 s into a
# CD boot: a 0x300 data-access exception inside
# com.apple.iokit.IOSCSIMultimediaCommandsDevice / IODVDStorageFamily, i.e. its
# ATAPI CD stack cannot drive QEMU's emulated optical device. Verbose boot
# (-prom-env 'boot-args=-v') is what showed this; the non-verbose failure is
# only the four-language "You need to restart your computer" panel. 10.3.0
# Panther booted the SAME device set to a painted Aqua installer in ~7 minutes
# with no panic. Do not "upgrade" this station back to Jaguar.
#
# via=pmu IS MANDATORY (inherited from macos9): the default via=cuda breaks the
# machine's USB HID.
#
# -device usb-tablet IS DELIBERATE AND IS THE POINTER. Unlike Mac OS 9 — which
# has no driver for it, and therefore forces the daemon's abs->rel bridge —
# Mac OS X 10.3 drives QEMU's absolute tablet directly. MEASURED on the Panther
# installer's framebuffer: QMP `abs` events to (200,150) and (800,600) put the
# guest arrow at those pixels, and a click at the Continue button's coordinates
# activated Continue. That makes this the museum's first mac99 station with a
# TRUE absolute pointer: no cursor scale, no re-home bridge, no reset teleport.
# The macos9 warning about a second HID pair splitting QEMU's input routing
# does NOT reproduce under OS X's HID manager — but it is still one tablet
# only; do NOT also add -device usb-mouse/usb-kbd.
#
# TCG, NO KVM: ppc guest on x86 host.
#
# NO NIC (-nic none): operator scope for this add is an ordinary station, no
# retronet. QEMU would otherwise auto-create a user-mode sungem on mac99.
# If networking is ever wanted it must go in BEFORE the first `savevm golden`
# — a NIC added afterwards is a device-set change and a full re-bake.
#
# NO AUDIO: QEMU's mac99 has no sound device in this fork.
#
# CHECKPOINT MODE (resetMode=loadvm): boots the persistent station-LOCAL qcow2
# (NO -snapshot) so QMP savevm/loadvm can create/restore "golden" in it.
set -e
D=/data/vms/streamhost/stations/macosx
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/macosx-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (fork patch); its run-state idle gate keeps a
# paused TCG station at ~0 cost.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden -S (or vanish on a cold boot)
nohup /opt/qemu-ppc/bin/qemu-system-ppc \
  -name streamhost-macosx \
  -accel tcg -m 1024 \
  -M mac99,via=pmu -cpu g4 \
  -g 1024x768x32 \
  -display dbus,p2p=on \
  -nic none \
  -device usb-tablet \
  -drive file=$D/macosx-golden.qcow2,format=qcow2,cache=writeback,aio=threads \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for _ in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "station macosx qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54218 loadvm='${LOADVM:-<none: cold boot>}' (checkpoint, no -snapshot)"
