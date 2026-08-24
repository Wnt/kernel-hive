#!/bin/bash
# Launch station 'hpuxvue' (slot 144) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# HP-UX 10.20 with HP VUE on an emulated HP 9000/778 (Visualize B160L,
# PA-7300LC) — a foreign-architecture QEMU station in the macos753 mould.
#
# THE BINARY IS NOT pve-qemu. The fleet package ships no hppa target, so this
# station runs a standalone build of the kernel-hive QEMU fork
# (github.com/Wnt/qemu, branch kernel-hive) installed at /opt/qemu-hppa; the
# SeaBIOS-hppa firmware (hppa-firmware.img) is the one that build installs
# beside it under share/qemu, found by the binary's default -L path. Rebuild:
#   ../configure --target-list=hppa-softmmu --enable-slirp --enable-dbus-display \
#     --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice \
#     --disable-opengl --disable-werror --disable-tools --prefix=/opt/qemu-hppa
#   ninja && ninja install
#
# TCG, NO KVM. PA-RISC has no hardware acceleration path; the station burns a
# host core whenever the guest runs. `-d nochain` is part of the recipe HP-UX
# is known to boot with under TCG (catalog + virtuallyfun writeup), not a
# debugging leftover — keep it until a boot WITHOUT it is proven.
#
# GRAPHICS: the built-in Artist framebuffer, 1280x1024 HARD CEILING — higher
# modes crash or leave dtwm/vuewm's pointer unable to reach y>=1146.
#
# RETRONET BRIDGE (2026-08-23): n0 is a real bridged NIC on vmbr-rn, NOT slirp.
# rn-tapnet.sh (called `up` just below, idempotently, like irix/tapnet.sh)
# creates the persistent tap hpuxrn0, enslaves it to vmbr-rn, and installs a
# fail-closed guest-containment chain. The guest is on DHCP (retronet-dhcp
# reservation RN_HPUXVUE_MAC -> 10.99.0.20/24, DNS 10.99.0.2, NO router) with NO
# default route; it shares L2 with the gateway CT 10.99.0.2, so it gets real
# ICMP/UDP/multi-connection TCP and browses the corpus by URL with no proxy.
# The -device is UNCHANGED (tulip, netdev=n0) apart from the per-station mac=.
# NOTE the backend swap was NOT invisible to loadvm on this machine: the old
# golden's vmstate carried a 'slirp' section and refused to load on the tap
# (docs/lab/retronet/WEB-STATION-hpuxvue.md), so the golden was cold re-baked
# on the tap. Do NOT renumber n0, and recapture the golden after ANY netdev
# change here.
#
# POINTER: LASI PS/2, relative only (no USB on this machine, no tablet), so
# the daemon runs SH_INPUT_BACKEND=dbus-rel. SH_CURSOR_SCALE is 1.0 until
# measured against the installed desktop (see station.env.fixture).
#
# THREE LAUNCH SHAPES, decided by what exists in $D:
#   1. golden snapshot in the disk  -> -loadvm golden -S (the exhibit; frozen
#      at the VUE desktop until the first visitor)
#   2. $D/INSTALLED marker          -> cold boot from the SCSI disk (-boot c)
#   3. neither                      -> INSTALL PHASE: cold boot the Install and
#      Core OS CD (-boot d) against a fresh/persistent install disk. This is
#      the dark-launch shape: the installer runs on camera at /os/hpuxvue.
# The DEVICE SET IS IDENTICAL in all three (CD drive always attached with the
# same ISO, same disk, same NIC) so a checkpoint baked in shape 2 loads in
# shape 1 — loadvm requires it.
set -e
D=/data/vms/streamhost/stations/hpuxvue
A=/data/vms/streamhost/assets/hpuxvue
QEMU=/opt/qemu-hppa/bin/qemu-system-hppa
DISK=$D/hpuxvue-golden.qcow2
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid" "$D/serial.sock"
[ -f "$DISK" ] || qemu-img create -f qcow2 "$DISK" 4000M >/dev/null
BOOT="-boot d"
LOADVM=""
if qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden; then
  LOADVM="-loadvm golden -S"
  BOOT="-boot c"
elif [ -f "$D/INSTALLED" ]; then
  BOOT="-boot c"
fi
# streamhost display fast-poll: dbus poll every SH_DBUS_UPDATE_MS ms (fork
# patch; its run-state idle gate keeps a paused TCG station at ~0 cost).
# Retronet link: create/enslave the vmbr-rn tap + arm the guest-containment
# chain BEFORE QEMU opens it (script=no means QEMU attaches to an existing tap,
# it does not create one). Idempotent; runs as root under streamhost@ / the
# golden-bake manual path. Fail-closed: if it cannot verify containment it dies
# here and QEMU never starts.
bash "$D/rn-tapnet.sh" up
# Guest NIC MAC. Real per-station MACs are NEVER committed (AGENTS.md); the real
# value lives in gitignored registry/local.env as RN_HPUXVUE_MAC (retronet fleet
# scheme 52:54:00:52:4e:<last-IP-octet>, "52:4e"=RN, .20 -> ...14) so every
# bridged guest is L2-distinct and per-MAC DHCP reservations do not collide. The
# golden's vmstate carries the MAC, so this only matters on a COLD (re-)bake;
# loadvm golden uses the baked MAC regardless, but this mac= must MATCH it (cold
# boot vs loadvm bind to the same device). Only the one line is read, never the
# whole (secret-bearing) file.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_HPUXVUE_MAC="02:00:00:00:00:14" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_HPUXVUE_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && RN_HPUXVUE_MAC="$_m"
fi
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM/$BOOT must word-split into flags
nohup "$QEMU" \
  -name streamhost-hpuxvue \
  -M B160L -accel tcg,thread=multi -smp 1 -m 512 -d nochain \
  -display dbus,p2p=on \
  -drive if=scsi,bus=0,index=6,file=$DISK,format=qcow2,cache=writeback,aio=threads \
  -drive if=scsi,bus=0,index=2,media=cdrom,file=$A/disc1.iso,format=raw,readonly=on \
  -netdev tap,id=n0,ifname=hpuxrn0,script=no,downscript=no -device tulip,netdev=n0,mac="$RN_HPUXVUE_MAC" \
  -serial unix:$D/serial.sock,server=on,wait=off \
  $BOOT $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "station hpuxvue qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54144 boot='$BOOT' loadvm='${LOADVM:-<none>}'"
