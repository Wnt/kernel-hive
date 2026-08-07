#!/bin/bash
# Launch tile 'tinycore' (VMID 82) QEMU with the streamhost display wiring.
# GOLDEN FIXTURE tile. Boots the TinyCore 17.x LiveCD (runs entirely in guest RAM)
# PLUS a persistent scratch qcow2 ('state.qcow2') whose ONLY purpose is to hold the
# live `savevm golden` VM-state snapshot (full RAM + device state). The LiveCD has no
# writable root disk, so this qcow2 is the only block device QEMU can store the golden
# reset point into. resetMode=loadvm  (see golden.env / golden.json).
#   * Runs WITHOUT -snapshot so `savevm golden` PERSISTS inside state.qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden), so the
#     tile comes up already at the curated fixture (screensaver/blank off, aterm open
#     with a steady non-blinking caret, clean keyboard-reactive prompt, clear desktop
#     + wbar for the mouse-reactive surface). First-ever bake (no snapshot yet)
#     launches cold -- see golden-bake.sh, which opens the terminal, applies the
#     tweaks, then `savevm golden`.
#   * NEVER delete state.qcow2 -- it IS the golden snapshot. Create-if-missing only.
#   * -boot d keeps booting the CD; the virtio disk is never booted/used by the guest.
#   * Disk is if=virtio,format=qcow2 -- matches the device model captured in the
#     snapshot, so -loadvm golden is portable across this launcher and the VNC setup one.
# Kill only by pidfile. neko is restored by ROLLBACK.md.
set -e
BASE=/data/vms/streamhost/tiles/tinycore
STATE="$BASE/state.qcow2"
BUILT_STATE=/data/gallery-guests/TinyCore/state.qcow2
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# Seed the runtime state from the canonical builder output once, then preserve it.
if [ ! -f "$STATE" ]; then
  [ -s "$BUILT_STATE" ] || {
    echo "missing TinyCore builder state: $BUILT_STATE" >&2
    exit 1
  }
  cp --reflink=auto "$BUILT_STATE" "$STATE"
fi
# Boot straight into the fixture if the golden snapshot is already present.
LOADVM=""
qemu-img snapshot -l "$STATE" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-tinycore \
  -enable-kvm -m 768 -smp 2 \
  -machine pc -cpu host \
  -rtc base=localtime \
  -drive file="$STATE",if=virtio,format=qcow2 -cdrom /data/isos/TinyCore.iso -boot d \
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
# unchanged and `-loadvm golden` still matches EXACTLY. Guest sshd (openssh.tcz) + eth0
# DHCP lease (10.0.2.15) + tc's authorized_keys all live in the golden snapshot.
# Login user is 'tc'. Key: /root/.ssh/gallery_guest_key.
[ -S "$BASE/qmp.sock" ] && python3 /root/qmp_hmp.py "$BASE/qmp.sock" 'hostfwd_add tcp:127.0.0.1:5882-10.0.2.15:22' >/dev/null 2>&1 || true
echo "tile tinycore qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54082 ssh=127.0.0.1:5882(tc) loadvm='${LOADVM:-<none: cold boot>}'"
