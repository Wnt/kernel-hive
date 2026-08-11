#!/bin/bash
# Launch tile 'alpine' (VMID 81) QEMU with the streamhost display wiring.
# GOLDEN FIXTURE tile. Boots the Alpine LiveCD (runs entirely in guest RAM) PLUS a
# persistent scratch qcow2 ('state.qcow2') whose ONLY purpose is to hold the live
# `savevm golden` VM-state snapshot (full RAM + device state). The LiveCD has no
# writable root disk, so this qcow2 is the only block device QEMU can store the
# golden reset point into. resetMode=loadvm  (see golden.env / golden.json).
#   * Runs WITHOUT -snapshot so `savevm golden` PERSISTS inside state.qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden), so the
#     tile comes up already at the curated fixture (screensaver/blank off, steady
#     caret, clean keyboard-reactive prompt). First-ever bake (no snapshot yet)
#     launches cold -- see golden-bake.sh, which types the tweaks then `savevm golden`.
#   * NEVER delete state.qcow2 -- it IS the golden snapshot. Create-if-missing only.
#   * -boot d keeps booting the CD; the empty IDE disk is never booted/mounted by the guest.
# Kill only by pidfile. neko is restored by ROLLBACK.md.
set -e
BASE=/data/vms/streamhost/stations/alpine
STATE="$BASE/state.qcow2"
BUILT_STATE=/data/gallery-guests/Alpine/state.qcow2
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# Seed the runtime state from the canonical builder output once, then preserve it.
if [ ! -f "$STATE" ]; then
  [ -s "$BUILT_STATE" ] || {
    echo "missing Alpine builder state: $BUILT_STATE" >&2
    exit 1
  }
  cp --reflink=auto "$BUILT_STATE" "$STATE"
fi
# Boot straight into the fixture if the golden snapshot is already present.
# -S rides the same conditional: restored guests start with vCPUs STOPPED (~0
# CPU until the first visitor session's cont — idle.rs wakes it sub-second);
# a first-ever bake (no snapshot yet) still cold-boots RUNNING for golden-bake.
LOADVM=""
qemu-img snapshot -l "$STATE" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-alpine \
  -enable-kvm -m 1024 -smp 2 \
  -cpu host \
  -rtc base=localtime \
  -cdrom /data/isos/Alpine.iso -boot d \
  -drive file="$STATE",if=ide,format=qcow2 \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
# ssh guest shell (gallery): re-establish the host->guest :22 forward. hostfwd is a
# host-side SLIRP property, NOT part of the golden VM-state snapshot, so it must be
# re-added on every cold QEMU start. Done via QMP (NOT a -device) => the device set is
# unchanged and `-loadvm golden` still matches EXACTLY. Guest sshd + eth0 IP live in
# the golden snapshot (savevm golden). Key: /root/.ssh/gallery_guest_key.
[ -S "$BASE/qmp.sock" ] && python3 /root/qmp_hmp.py "$BASE/qmp.sock" 'hostfwd_add tcp:127.0.0.1:5881-10.0.2.15:22' >/dev/null 2>&1 || true
echo "tile alpine qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54081 ssh=127.0.0.1:5881 loadvm='${LOADVM:-<none: cold boot>}'"
