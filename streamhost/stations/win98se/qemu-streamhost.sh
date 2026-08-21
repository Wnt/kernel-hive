#!/bin/bash
# Launch tile 'win98se' (VMID 92) QEMU with the streamhost display wiring.
# GOLDEN FIXTURE tile.  Windows 98 SE is a real disk-backed guest: both IDE disks
# (win98se-kvm.qcow2 = C:, win98se-games.qcow2 = D:) are qcow2, so the live
# `savevm golden` VM-state snapshot is stored INSIDE those base qcow2 disks.
# resetMode=loadvm  (see golden.env / golden.json).
#   * Runs WITHOUT -snapshot so `savevm golden` PERSISTS into the qcow2 disks.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden), so the
#     tile comes up already at the curated fixture (screensaver/DPMS off, steady
#     caret, Notepad input-reactive surface, taskbar clock hidden). First-ever bake
#     (no snapshot yet) launches cold -- see golden-bake.sh.
#   * Reset a running fixture to golden any time: bash golden-reset.sh (QMP loadvm).
#   * KVM accel with acpi=ON + -cpu pentium3 (apic ON, default irqchip) + a usb-tablet
#     is the validated combo (baked 2026-07-12). This golden is an ACPI-HAL install, so
#     acpi=on is REQUIRED for PCI enumeration (NIC + USB + the usb-tablet); acpi=off left
#     it on the fail-safe PnP BIOS with no PCI. usb-tablet -> absolute pointer (SH_POINTER=abs).
#     No protection error under acpi=on+KVM (verified 3 cold boots). Do NOT re-add
#     acpi=off/usb=off/-apic/kernel-irqchip=off. See docs/guests/win9x.md.
#   * RETRONET BRIDGE (2026-08-20): n0 is a real bridged NIC on vmbr-rn, NOT slirp.
#     rn-tapnet.sh (called `up` just below, idempotently, like irix/tapnet.sh)
#     creates the persistent tap win98rn0, enslaves it to vmbr-rn, and installs a
#     fail-closed guest-containment chain. The guest is on DHCP (retronet-dhcp
#     reservation RN_WIN98SE_MAC -> 10.99.0.10/24, DNS 10.99.0.2, NO router) with
#     NO default route; it shares L2 with the OSCAR gateway CT 10.99.0.2, so ICQ
#     gets working UDP + ICMP + real multi-connection TCP (what slirp's single-
#     connection guestfwd could not carry) and browses the corpus by URL with no
#     proxy. The -device is UNCHANGED (pcnet, netdev=n0) apart from the per-station
#     mac= — only the netdev backend went user->tap, which is invisible to
#     savevm/loadvm, so `loadvm golden` stays valid. Do NOT renumber n0.
#   * EXEC CHANNEL rides the same bridge now: labctl reaches C:\WARPNET.EXE (the
#     in-guest warpd agent, -DWARP_PORT=7788, exec_kind "warpd_e") DIRECTLY at the
#     guest's bridge IP 10.99.0.10:7788 — no hostfwd, since there is no slirp. The
#     agent binds 0.0.0.0:7788 and re-launches from the StartUp folder on a cold
#     boot. See docs/lab/retronet/ICQ-STATION.md, EXEC-CHANNEL.md, GATEWAY.md.
# Kill only by pidfile. neko is restored by ROLLBACK.md.
set -e
B=/data/vms/streamhost/stations/win98se
KVM=/data/gallery-guests/Win98SE/win98se-kvm.qcow2
GAMES=/data/gallery-guests/Win98SE/win98se-games.qcow2
[ -f "$B/qemu.pid" ] && kill "$(cat "$B/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$B/qmp.sock" "$B/qemu.pid"
# Boot straight into the fixture if the golden snapshot is already present in C:.
LOADVM=""
qemu-img snapshot -l "$KVM" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# Retronet link: create/enslave the vmbr-rn tap + arm the guest-containment
# chain BEFORE QEMU opens it (script=no means QEMU attaches to an existing tap,
# it does not create one). Idempotent; runs as root under streamhost@ / the
# golden-bake manual path. Fail-closed: if it cannot verify containment it dies
# here and QEMU never starts.
bash "$B/rn-tapnet.sh" up
# Guest NIC MAC. Real per-station MACs are NEVER committed (AGENTS.md); the real
# value lives in gitignored registry/local.env as RN_WIN98SE_MAC (retronet fleet
# scheme 52:54:00:52:4e:<last-IP-octet>, "52:4e"=RN, .10 -> ...0a) so every
# bridged guest is L2-distinct and per-MAC DHCP reservations do not collide. The
# golden's vmstate carries the MAC, so this only matters on a COLD (re-)bake;
# loadvm golden uses the baked MAC regardless, but this mac= must MATCH it (cold
# boot vs loadvm bind to the same device). Only the one line is read, never the
# whole (secret-bearing) file.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_WIN98SE_MAC="02:00:00:00:00:0a" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_WIN98SE_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && RN_WIN98SE_MAC="$_m"
fi
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-win98se \
  -enable-kvm -m 384 -smp 1 \
  -machine pc-i440fx-11.0,acpi=on -cpu pentium3 \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -drive file="$KVM",format=qcow2,if=ide \
  -drive file="$GAMES",format=qcow2,if=ide,index=1 \
  -netdev tap,id=n0,ifname=win98rn0,script=no,downscript=no -device pcnet,netdev=n0,mac="$RN_WIN98SE_MAC" \
  -usb -device usb-tablet,id=tab0 \
  $LOADVM \
  -qmp unix:$B/qmp.sock,server=on,wait=off \
  -pidfile $B/qemu.pid \
  >"$B/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$B/qmp.sock" ] && [ -f "$B/qemu.pid" ] && break
  sleep 0.5
done
echo "tile win98se qemu pid=$(cat $B/qemu.pid 2>/dev/null) qmp=$B/qmp.sock udp=54092 loadvm='${LOADVM:-<none: cold boot>}'"
