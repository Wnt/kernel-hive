#!/bin/bash
# Launch station 'chokanji' (VMID 149) QEMU with the streamhost display wiring.
#
# Chokanji / 超漢字 — B-right/V, the commercial BTRON3 desktop from Ken
# Sakamura's TRON project. This is a disk-backed guest: the IDE disk
# (chokanji.qcow2 = the whole machine) is qcow2, so the live `savevm golden`
# VM-state snapshot is stored INSIDE that base qcow2 disk. resetMode=loadvm
# (see station.env.fixture).
#   * Runs WITHOUT -snapshot so `savevm golden` PERSISTS into the qcow2 disk.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden -S),
#     so the station comes up already at the curated BTRON desktop, FROZEN
#     (~0 CPU); the first visitor session's cont (idle.rs) wakes it sub-second.
#     A first-ever bake (no snapshot yet) cold-boots RUNNING for the bake driver.
#
# DEVICE SET — do NOT change it; `loadvm golden` binds to exactly this set.
#   * KVM accel, -machine pc-i440fx-11.0 -cpu host, 256 MB (the amount the
#     B-right/V build in this disk was tuned for), std i8042 PS/2 keyboard.
#   * vmport=off is LOAD-BEARING. The disk was originally a VMware guest, so
#     QEMU's default VMware I/O port makes the `vmmouse` device the current
#     pointer and it SWALLOWS all injected motion — the BTRON hand cursor never
#     moves (query-mice shows vmmouse current, absolute=false; BTRON does not
#     poll the VMware port, so vmmouse never reaches absolute mode). Turning
#     vmport off removes vmmouse; the default i8042 PS/2 mouse then becomes the
#     live pointer and BTRON tracks it. (The Virtual OS Museum reaches the same
#     conclusion for B-right/V: run it with vmport off.)
#   * PS/2 RELATIVE pointer (default i8042 mouse, no -device): BTRON's driver is
#     a plain relative mouse, so SH_POINTER=rel and the UI pointerRel=true feed
#     browser Pointer Lock 1:1 deltas. usb-tablet (absolute) does NOT move the
#     cursor on this guest; PS/2 relative works once vmmouse is out of the way.
#   * -vga cirrus: the BTRON screen driver in this disk drives the Cirrus
#     GD5446 at 800x600. (std VGA renders black — the driver is Cirrus-specific.)
#   * NO NIC: this station has no network at all (no retronet, no slirp). BTRON
#     boots straight to the desktop without one.
#   * NO audio device yet: the BTRON desktop is effectively silent; SB16 (what
#     the original QEMU-CKJ q.bat used) is a possible future add.
# Kill only by pidfile. Full rationale + media provenance: docs/guests/chokanji.md.
set -e
B=/data/vms/streamhost/stations/chokanji
DISK=/data/gallery-guests/Chokanji/chokanji.qcow2
[ -f "$B/qemu.pid" ] && kill "$(cat "$B/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$B/qmp.sock" "$B/qemu.pid"
# Boot straight into the curated fixture if the golden snapshot is already
# present inside the disk; otherwise cold-boot RUNNING for a first-ever bake.
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost QEMU display-capture fast-poll (pve-qemu 0047 patch): dbus display
# polls every SH_DBUS_UPDATE_MS ms (default 4; clamp 1..29; 0/unset = stock 30 ms).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden -S (or vanish on a cold boot)
nohup qemu-system-x86_64 \
  -name streamhost-chokanji \
  -enable-kvm -m 256 -smp 1 \
  -machine pc-i440fx-11.0,vmport=off -cpu host \
  -rtc base=localtime \
  -boot c \
  -vga cirrus \
  -display dbus,p2p=on \
  -drive file="$DISK",format=qcow2,if=ide \
  $LOADVM \
  -qmp unix:"$B/qmp.sock",server=on,wait=off \
  -pidfile "$B/qemu.pid" \
  >"$B/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$B/qmp.sock" ] && [ -f "$B/qemu.pid" ] && break
  sleep 0.5
done
echo "station chokanji qemu pid=$(cat "$B/qemu.pid" 2>/dev/null) qmp=$B/qmp.sock udp=54149 loadvm='${LOADVM:-<none: cold boot>}'"
