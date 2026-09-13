#!/bin/bash
# Launch tile 'magiccap' (VMID 197) QEMU with the streamhost display wiring.
# GUEST: General Magic's Magic Cap for Windows, pre-release build 327 (1995),
# installed as a Windows application (C:\MAGICCAP\MCW.EXE) inside a win98se-class
# Windows 98 SE guest. Same emulated i440fx device set as win98se; the only
# device-level difference is the NIC backend (see NETWORK below).
# GOLDEN FIXTURE tile. Both IDE disks (magiccap-c.qcow2 = C:, magiccap-d.qcow2 = D:)
# are qcow2, so the live `savevm golden` VM-state snapshot is stored INSIDE those
# base qcow2 disks — the same file the guest boots from, not a side vmstate file.
# NEVER delete or replace either qcow2 without recapturing golden first
# (checkpoint-guard recapture magiccap): doing so throws away the only copy of
# the fixture, and `loadvm golden` on a fresh disk fails outright.
# resetMode=loadvm  (see golden.env / golden.json).
#   * Runs WITHOUT -snapshot so `savevm golden` PERSISTS into the qcow2 disks.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden -S), so
#     the tile comes up already at the curated fixture. First-ever bake (no
#     snapshot yet) launches cold — see scripts/build-guests/tiles/magiccap.sh,
#     which composes C:\MAGICCAP and drives the in-guest bake steps.
#   * Reset a running fixture to golden any time: QMP loadvm (see qmp.py / shot.sh).
#   * KVM accel with acpi=ON + -cpu pentium3 + a usb-tablet is the win98se-proven
#     combo (device set unchanged from win98se — only the NIC backend differs).
#     usb-tablet -> absolute pointer (SH_POINTER=abs). See docs/guests/win9x.md.
#
# NETWORK — slirp, NOT the retronet tap (rule 15: a station only gets an
# rn-tapnet.sh once it has a PROVEN retronet join; magiccap has none). This is
# also the deliberate sandbox boundary for this station: `-netdev
# user,id=n0,restrict=on` is QEMU's built-in NAT/DHCP stack running entirely in
# the host QEMU process — no host directory share, no hostfwd port, no virtio-
# serial channel to the host, and restrict=on additionally blocks the guest from
# reaching the host's other interfaces. Combined with QMP being a unix socket
# under this station dir (not exposed to the guest) and no 9p/virtfs mount, the
# visitor's reach ends at the emulated PC — there is no path out of the guest.
# Do not add a tap, a hostfwd rule, or a shared-folder device to "fix" a
# perceived limitation without re-reading docs/lab/MAGICCAP-WAVE.md §Sandbox.
#
# WIN.INI TRAP (see docs/lab/MAGICCAP-WAVE.md): the golden's C:\WINDOWS\WIN.INI
# does NOT autostart Magic Cap via a `run=` line — `run=` takes a SPACE-
# SEPARATED LIST of programs, so `run=regedit /s C:\MC.REG` launches `regedit`
# and then tries to run a program literally named `s`, producing a "Could not
# load or run 's'" dialog on every boot (frame:
# /data/vms/sandbox/magiccap/smoke/f-boot2.png). Autostart is instead the
# HKLM\...\CurrentVersion\Run value `MagicCap` = `C:\MAGICCAP\MCW.EXE`, applied
# once by importing C:\MC.REG (regedit /s C:\MC.REG from Start > Run, never from
# WIN.INI). Do not "fix" this by adding a run= line back.
# Kill only by pidfile.
set -e
B=/data/vms/streamhost/stations/magiccap
# Disk paths: inferred from the win98se pattern (asset dir named for the
# station, same C:/D: split). Not yet confirmed by the station lead — if the
# actual bake places these elsewhere, update KVM/GAMES below and say so in the
# handoff; nothing else in this launcher depends on the exact path.
KVM=/data/vms/streamhost/assets/magiccap/magiccap-c.qcow2
GAMES=/data/vms/streamhost/assets/magiccap/magiccap-d.qcow2
[ -f "$B/qemu.pid" ] && kill "$(cat "$B/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$B/qmp.sock" "$B/qemu.pid"
# Boot straight into the fixture if the golden snapshot is already present in C:.
LOADVM=""
qemu-img snapshot -l "$KVM" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# Guest NIC MAC: placeholder, committed on purpose (AGENTS.md rule 1 — never a
# real value in git). This station has no retronet reservation, so there is no
# gitignored local.env lookup here (unlike win98se's bridged NIC).
MAGICCAP_MAC="02:00:00:00:00:c5"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-magiccap \
  -enable-kvm -m 384 -smp 1 \
  -machine pc-i440fx-11.0,acpi=on -cpu pentium3 \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -drive file="$KVM",format=qcow2,if=ide \
  -drive file="$GAMES",format=qcow2,if=ide,index=1 \
  -netdev user,id=n0,restrict=on -device pcnet,netdev=n0,mac="$MAGICCAP_MAC" \
  -usb -device usb-tablet,id=tab0 \
  $LOADVM \
  -qmp unix:$B/qmp.sock,server=on,wait=off \
  -pidfile $B/qemu.pid \
  >"$B/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$B/qmp.sock" ] && [ -f "$B/qemu.pid" ] && break
  sleep 0.5
done
echo "tile magiccap qemu pid=$(cat $B/qemu.pid 2>/dev/null) qmp=$B/qmp.sock udp=54197 loadvm='${LOADVM:-<none: cold boot>}'"
