#!/bin/bash
# Launch tile 'win2000' (VMID 93) QEMU with the streamhost display wiring.
# GOLDEN FIXTURE tile.  Windows 2000 Pro is a disk-backed guest: the IDE disk
# (win2k-pro.qcow2 = C:) is qcow2, so the live `savevm golden` VM-state snapshot
# is stored INSIDE that base qcow2 disk.  resetMode=loadvm (see station.env.fixture).
#   * Runs WITHOUT -snapshot so `savevm golden` PERSISTS into the qcow2 disk.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden -S), so
#     the tile comes up already at the curated fixture, FROZEN (~0 CPU); the first
#     visitor session's cont (idle.rs) wakes it sub-second.  A first-ever bake (no
#     snapshot yet) cold-boots RUNNING for the bake to drive.
#   * KVM accel, -machine pc-i440fx-11.0 -cpu host, std VGA (VBEMP-NT framebuf,
#     1600x1200x32), AC97 audio, usb-tablet (absolute pointer, SH_POINTER=abs),
#     rtl8139 NIC.  Do NOT change the device set: `loadvm golden` binds to it.
#   * RETRONET BRIDGE (2026-08-20): n0 is a real bridged NIC on vmbr-rn, NOT slirp.
#     rn-tapnet.sh (called `up` just below, idempotently, like win98se/irix) creates
#     the persistent tap win2krn0, enslaves it to vmbr-rn, and installs a fail-closed
#     guest-containment chain (WIN2KRN-IN). The guest is static 10.99.0.11/24 with
#     NO default route; it shares L2 with the OSCAR gateway CT 10.99.0.2, so ICQ
#     2000b gets working UDP + ICMP + real multi-connection TCP (what slirp's
#     single-connection guestfwd could not carry). The -device is UNCHANGED
#     (rtl8139,netdev=n0) — only the netdev backend went user->tap, which is
#     invisible to savevm/loadvm, so `loadvm golden` stays valid. Do NOT renumber n0.
#   * EXEC CHANNEL rides the same bridge: labctl reaches C:\WARPNET.EXE (the
#     in-guest warpd agent, -DWARP_PORT=7788, exec_kind "warpd_e") DIRECTLY at the
#     guest's bridge IP 10.99.0.11:7788 — no hostfwd, since there is no slirp. The
#     agent binds 0.0.0.0:7788 and re-launches from the StartUp folder on a cold
#     boot. See docs/lab/retronet/ICQ-STATION-win2000.md, ICQ-STATION.md, GATEWAY.md.
# Kill only by pidfile. Stop/restore procedure for this one tile: ROLLBACK.md.
set -e
B=/data/vms/streamhost/stations/win2000
DISK=/data/gallery-guests/Win2000/win2k-pro.qcow2
[ -f "$B/qemu.pid" ] && kill "$(cat "$B/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$B/qmp.sock" "$B/qemu.pid"
# Boot straight into the fixture if the golden snapshot is already present in C:.
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# Retronet link: create/enslave the vmbr-rn tap + arm the guest-containment chain
# BEFORE QEMU opens it (script=no means QEMU attaches to an existing tap, it does
# not create one). Idempotent; runs as root under streamhost@ / the manual bake
# path. Fail-closed: if it cannot verify containment it dies here and QEMU never
# starts.
bash "$B/rn-tapnet.sh" up
# streamhost QEMU display-capture fast-poll (pve-qemu 0047 patch): dbus display
# polls every SH_DBUS_UPDATE_MS ms (default 4; clamp 1..29; 0/unset = stock 30 ms).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden -S (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-win2000 \
  -enable-kvm -m 512 -smp 1 \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -drive file="$DISK",format=qcow2,if=ide \
  -netdev tap,id=n0,ifname=win2krn0,script=no,downscript=no -device rtl8139,netdev=n0 \
  $LOADVM \
  -qmp unix:$B/qmp.sock,server=on,wait=off \
  -pidfile $B/qemu.pid \
  >"$B/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$B/qmp.sock" ] && [ -f "$B/qemu.pid" ] && break
  sleep 0.5
done
echo "tile win2000 qemu pid=$(cat $B/qemu.pid 2>/dev/null) qmp=$B/qmp.sock udp=54093 loadvm='${LOADVM:-<none: cold boot>}'"
