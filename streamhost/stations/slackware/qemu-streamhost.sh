#!/bin/bash
# Launch station 'slackware' (VMID 184) QEMU with the streamhost display wiring.
# Slackware 3.4 (Oct 1997): Linux 2.0.30 'bare.i', XFree86 3.3.1 XF86_SVGA on the
# emulated Cirrus CL-GD5446, fvwm95 desktop at 1024x768x16.
#   * disk.qcow2 is the ONLY writable block device: a 400 MiB rev-0 ext2 root composed
#     HOST-SIDE from the mirror's .tgz packages (scripts/build-guests/tiles/slackware/compose.sh),
#     and it carries the savevm 'golden' vmstate. Copied from the builder output on first
#     launch; NEVER delete or replace it — recapture only via `checkpoint-guard recapture slackware`.
#   * grub-boot.iso (read-only CD, secondary master) is the boot loader: GRUB2 `linux16`
#     loads the stock zImage with root=/dev/hda1. The 1997 LILO boot floppy wedges at "LI"
#     under SeaBIOS and QEMU's own -kernel loader hangs this zImage before decompression,
#     so the ISO IS part of the device set (the vmstate was baked with it attached).
#   * -vga cirrus: XFree86 3.3.1 has no driver for -vga std beyond 16 colours; the cirrus
#     driver needs Option "no_bitblt" (BitBLT emulation drops xterm text) and "sw_cursor".
#   * POINTER: ABSOLUTE through the guest's own X server (x11warp): slirp user-net with a
#     loopback forward 127.0.0.1:6084 -> 10.0.2.15:6000, NE2000 ISA (ne.o module, io 0x300)
#     in the guest, `xhost +10.0.2.2` in the session; the daemon does XWarpPointer +
#     XQueryPointer readback. Buttons still travel the Microsoft serial mouse on ttyS0
#     (QEMU msmouse chardev), which is also the relative fallback. The hostfwd is
#     host-side state, not vmstate, so the launcher re-declares it on every start.
#   * sb16 + PC speaker -> dbus audiodev (the desktop only beeps).
#   * KVM, -cpu host, 32 MB, 1 vCPU: kernel 2.0 is happiest under 64 MB.
# Kill only by pidfile.
set -e
BASE=/data/vms/streamhost/stations/slackware
DISK="$BASE/disk.qcow2"
BUILT=/data/gallery-guests/Slackware
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
[ -f "$DISK" ] || cp "$BUILT/slackware.qcow2" "$DISK"
[ -f "$BASE/grub-boot.iso" ] || cp "$BUILT/grub-boot.iso" "$BASE/grub-boot.iso"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms (default 4).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-slackware \
  -enable-kvm -m 32 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0 -cpu host \
  -rtc base=localtime \
  -boot d \
  $LOADVM \
  -vga cirrus \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -chardev msmouse,id=ms0 -serial chardev:ms0 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:6084-10.0.2.15:6000 -device ne2k_isa,netdev=n0 \
  -drive file=/data/vms/streamhost/stations/slackware/disk.qcow2,format=qcow2,if=ide \
  -drive file=/data/vms/streamhost/stations/slackware/grub-boot.iso,format=raw,if=ide,index=2,media=cdrom,readonly=on \
  -qmp unix:/data/vms/streamhost/stations/slackware/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/stations/slackware/qemu.pid \
  >"/data/vms/streamhost/stations/slackware/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "station slackware qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54184 loadvm='${LOADVM:-<none: cold boot>}'"
