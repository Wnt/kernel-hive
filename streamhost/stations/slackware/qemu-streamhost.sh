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
#   * RETRONET: the ONE NIC is a bridge port on vmbr-rn (tap slackwarern0), not slirp.
#     The -device is unchanged (ne2k_isa, the ne.o module at io 0x300 that bare.i ships);
#     only the netdev backend went user -> tap, plus a unique MAC. The guest is addressed
#     STATICALLY at 10.99.0.31/24 with NO default route (Slackware 3.4 predates DHCP on
#     this media), which is also retronet containment Lock 2. rn-tapnet.sh (called `up`
#     just below, idempotently, like chokanji's) creates the tap and installs the
#     fail-closed SLACKWARERN-IN chain; QEMU never starts if that does not verify.
#   * POINTER: ABSOLUTE through the guest's own X server (x11warp), now straight over the
#     bridge: the daemon opens 10.99.0.31:6000 and does XWarpPointer + XQueryPointer
#     readback. The slirp hostfwd 127.0.0.1:6084 it used before is GONE — there is no
#     slirp any more — so SH_X11WARP_DISPLAY is the guest's own address and the guest's
#     session runs `xhost +10.99.0.1` (the bridge address labhost sources from). Buttons
#     still travel the Microsoft serial mouse on ttyS0 (QEMU msmouse chardev), which is
#     also the relative fallback.
#   * The same one link carries the museum web (proxy 10.99.0.2:3128, Arena), ICQ (the
#     gateway's pre-OSCAR UDP 4000 door, micq as UIN 18400) and the exec channel
#     (in.telnetd behind inetd at 10.99.0.31:23, tcpd-restricted to 10.99.0.1).
#   * sb16 + PC speaker -> dbus audiodev (the desktop only beeps).
#   * KVM, -cpu host, 32 MB, 1 vCPU: kernel 2.0 is happiest under 64 MB.
# Kill only by pidfile.
set -e
BASE=/data/vms/streamhost/stations/slackware
# UNIQUE per-station MAC on vmbr-rn (retronet scheme 52:4e:<last IP octet>). The whole
# QEMU fleet otherwise boots QEMU's one default MAC, and two of them on one bridge
# collapse to a single FDB entry. The real value is box-local (gitignored
# registry/local.env, RN_SLACKWARE_MAC); the committed fallback is a scrubbed
# placeholder. The MAC lives in the golden's device vmstate, so changing it needs a
# COLD re-bake — `loadvm golden` restores the baked MAC whatever this says.
RN_SLACKWARE_MAC="02:00:00:00:00:1f" # placeholder (committed); real value from local.env
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^[[:space:]]*RN_SLACKWARE_MAC=//p' "$RN_LOCAL_ENV" | tail -1 | tr -d '\042\047')"
  [ -n "$_m" ] && RN_SLACKWARE_MAC="$_m"
fi
# Containment BEFORE the guest: the tap, its bridge port and the fail-closed
# SLACKWARERN-IN chain. Under `set -e` a failure here means QEMU never starts, so an
# uncontained guest is not a state this station can reach.
bash "$BASE/rn-tapnet.sh" up
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
  -netdev tap,id=rn0,ifname=slackwarern0,script=no,downscript=no -device ne2k_isa,netdev=rn0,mac="$RN_SLACKWARE_MAC" \
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
