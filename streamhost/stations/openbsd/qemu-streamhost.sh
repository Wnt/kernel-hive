#!/bin/bash
# Launch station 'openbsd' (VMID 177) QEMU with the streamhost display wiring.
# OpenBSD 7.9 amd64 (May 2026), Xenocara + fvwm 2.2.5 from base, on KVM.
#   * disk.qcow2 is the ONLY block device (4 GiB virtio, whole-disk auto layout) and
#     carries the savevm 'golden' vmstate, so loadvm restores RAM + filesystem.
#     Copied from the builder output on first launch; NEVER delete or replace it —
#     recapture only via `checkpoint-guard recapture openbsd`.
#   * Runs WITHOUT -snapshot; boots straight into 'golden' when it exists, otherwise
#     cold-boots: /etc/ttys runs /root/kh-autologin (login -f root) on ttyC0 ->
#     ~/.profile -> startx -> ~/.xinitrc (xterm, xclock, xeyes, xcalc) -> fvwm.
#   * -vga none -device VGA,edid=on,xres=1024,yres=768: the same bochs stdvga as
#     -vga std, with an EDID whose preferred mode pins the Xorg vesa server to
#     1024x768 (plain -vga std advertises 1920x1200 and X takes it).
#   * usb-tablet -> ums0/wsmouse0 -> xf86-input-ws: ABSOLUTE pointer.
#   * AC97 (auich) -> sndio -> dbus audiodev.
#   * virtio-net on SLIRP (vio0, autoconf): the guest can reach out, nothing reaches in.
# Kill only by pidfile.
set -e
BASE=/data/vms/streamhost/stations/openbsd
DISK="$BASE/disk.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
[ -f "$DISK" ] || cp --reflink=auto /data/gallery-guests/OPENBSD/openbsd.qcow2 "$DISK"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms (default 4).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# -S rides the same conditional: restored guests start with vCPUs STOPPED until the
# first visitor session's cont; a first-ever bake (no snapshot yet) cold-boots RUNNING.
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-openbsd \
  -enable-kvm -m 1024 -smp 2 \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -boot c \
  $LOADVM \
  -drive file=/data/vms/streamhost/stations/openbsd/disk.qcow2,format=qcow2,if=virtio \
  -vga none -device VGA,edid=on,xres=1024,yres=768 \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -qmp unix:/data/vms/streamhost/stations/openbsd/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/stations/openbsd/qemu.pid \
  >"/data/vms/streamhost/stations/openbsd/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "station openbsd qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54177 loadvm='${LOADVM:-<none: cold boot>}'"
