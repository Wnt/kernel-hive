#!/bin/bash
# Launch tile 'winxp' (VMID 94) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# GOLDEN FIXTURE MODE (resetMode=loadvm, see GOLDEN.md):
#   * Boots the persistent tile-LOCAL golden qcow2 (NO -snapshot) so QMP
#     savevm/loadvm can create/restore the live "golden" reset point IN it. The
#     disk is a standalone qcow2 (no backing dep), a curated copy of the pristine
#     gallery image which stays untouched at /data/gallery-guests/WinXPpro/winxp.qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden) so the
#     tile comes up already at the curated fixture (Notepad open+focused, steady
#     caret, screensaver off, tray clock hidden). First-ever bake (no snapshot yet)
#     launches cold -- see golden-bake.sh.
#   * RETRONET BRIDGE (2026-08-23): n0 is a real bridged NIC on vmbr-rn, NOT slirp.
#     rn-tapnet.sh (called `up` just below, idempotently, like win98se/win2000) creates
#     the persistent tap winxprn0, enslaves it to vmbr-rn, and installs a fail-closed
#     guest-containment chain (WINXPRN-IN). The guest is on DHCP (retronet-dhcp
#     reservation RN_WINXP_MAC -> 10.99.0.18/24, DNS 10.99.0.2, NO router) with NO
#     default route; it shares L2 with the gateway CT 10.99.0.2, so IE6 browses the
#     corpus by URL with no proxy (wildcard DNS -> the gateway's :80 origin) and ICMP
#     works. The -device is UNCHANGED (rtl8139,netdev=n0) apart from the per-station
#     mac= -- the netdev BACKEND went user->tap, which is invisible to savevm/loadvm,
#     so `loadvm golden` stays valid. Do NOT renumber n0 or change the device set.
#     See docs/lab/retronet/WEB-STATION-winxp.md, WEB-PROXY.md, GATEWAY.md.
set -e
D=/data/vms/streamhost/stations/winxp
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/winxp-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# Retronet link: create/enslave the vmbr-rn tap + arm the guest-containment chain
# BEFORE QEMU opens it (script=no means QEMU attaches to an EXISTING tap, it does
# not create one). Idempotent; runs as root under streamhost@ / the manual bake
# path. Fail-closed: if it cannot verify containment it dies here and QEMU never
# starts.
bash "$D/rn-tapnet.sh" up
# Guest NIC MAC. Real per-station MACs are NEVER committed (AGENTS.md); the real
# value lives in gitignored registry/local.env as RN_WINXP_MAC (retronet fleet
# scheme 52:54:00:52:4e:<last-IP-octet>, "52:4e"=RN, .18 -> ...12) so every
# bridged guest is L2-distinct and per-MAC DHCP reservations do not collide. The
# golden's vmstate carries the MAC, so this only matters on a COLD (re-)bake;
# loadvm golden uses the baked MAC regardless, but this mac= must MATCH it (cold
# boot vs loadvm bind to the same device). Only the one line is read, never the
# whole (secret-bearing) file.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_WINXP_MAC="02:00:00:00:00:12" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_WINXP_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && RN_WINXP_MAC="$_m"
fi
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-winxp \
  -enable-kvm -m 768 -smp 1 \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -cdrom /data/gallery-guests/WinXPpro/retro-software.iso -boot order=c,menu=off \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -drive file=$D/winxp-golden.qcow2,format=qcow2,if=ide \
  -netdev tap,id=n0,ifname=winxprn0,script=no,downscript=no -device rtl8139,netdev=n0,mac="$RN_WINXP_MAC" \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile winxp qemu pid=$(cat $D/qemu.pid 2>/dev/null) qmp=$D/qmp.sock udp=54094 loadvm='${LOADVM:-<none: cold boot>}' (golden, no -snapshot)"
