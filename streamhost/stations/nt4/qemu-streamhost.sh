#!/bin/bash
# Launch tile 'nt4' (VMID 89) QEMU with the streamhost display wiring.
# Windows NT 4.0 Workstation SP6a — native x86, KVM-fast, on the retronet bridge.
# Kill only by pidfile.
#
# GOLDEN FIXTURE MODE (resetMode=loadvm, see GOLDEN.md):
#   * Boots the persistent tile-LOCAL golden qcow2 (NO -snapshot) so QMP
#     savevm/loadvm can create/restore the live "golden" reset point IN it. The
#     disk is a standalone qcow2 (no backing dep), a curated copy of the
#     gallery image which stays untouched at /data/gallery-guests/Nt4/nt4-golden.qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden) so
#     the tile comes up already at the curated fixture. First-ever bake (no
#     snapshot yet) launches cold at the NT4 desktop -- see golden-bake.sh.
#
# DISPLAY / MAINTENANCE:
#   NT uses its SP6a Cirrus driver at 1024x768x16bpp. This tile pins the
#   dedicated QEMU build carrying both:
#     streamhost/qemu-patches/0004-cirrus-blt-rop1-fill.patch
#     streamhost/qemu-patches/0005-cirrus-isa-vmstate-descend-substruct.patch
#   Patch 0004 fixes accelerated fills during scroll/window redraw. Patch 0005
#   makes fresh-process -loadvm golden restore the ISA Cirrus substructure
#   correctly. Rebuild and reverify /opt/qemu-cirrusfix2 whenever the packaged
#   QEMU version changes. /opt/qemu-cirrusfix is intentionally reserved for
#   nt351 and must not be changed as part of NT4 maintenance.
#
# HARD DEVICE-SET GOTCHAS (NT4, from catalog §4 + first-light 2026-07-27):
#   * -cpu pentium3          : the HOST cpu model BSODs NT4 setup/boot. NT4
#                              predates modern CPUID leaves; pentium3 is the
#                              newest model NT4 tolerates.
#   * -smp 1                 : NT4 was installed with the UNIPROCESSOR HAL.
#                              Booting SMP with a UP HAL -> STOP 0x0000003E / hang.
#   * -machine pc-...,hpet=off: HPET confuses NT4's HAL timer setup.
#   * vmport=on             : QEMU 11 auto-instantiates its vmmouse on i8042.
#                              The preserved NT4 VMware vmmouse.sys driver
#                              consumes it as true absolute 1:1 input. Adding a
#                              second explicit -device vmmouse is invalid
#                              ('i8042 link is not set') on this QEMU version.
#   * isa-cirrus-vga         : the SP6a Cirrus driver provides accelerated
#                              1024x768x65536-color output. global-vmstate=on
#                              is part of the saved golden device contract.
#   * -device pcnet          : pinned NIC device, UNCHANGED (the -device is what
#                              savevm/loadvm bind to). RETRONET BRIDGE (2026-08-20):
#                              n0 is a real bridged NIC on vmbr-rn, NOT slirp. The
#                              in-guest AMD PCNET driver (amdpcn.sys, Start=2) and
#                              its TCP/IP binding are enabled in the tap-native
#                              golden; the guest is static 10.99.0.12/24 with NO
#                              default route, sharing L2 with the OSCAR gateway CT
#                              10.99.0.2 so ICQ 2000b gets working UDP + ICMP +
#                              real multi-connection TCP. Only the netdev BACKEND
#                              went user->tap, invisible to savevm/loadvm. Do NOT
#                              renumber n0. See docs/lab/retronet/ICQ-STATION-NT4.md.
#   * exec channel           : rides the same bridge — labctl reaches C:\WARPNET.EXE
#                              (warpnet7788.exe, exec_kind "warpd_e") DIRECTLY at
#                              10.99.0.12:7788; no hostfwd. Autostarts from the
#                              All Users StartUp folder on a cold boot.
#   * boot.ini ARC path      : the prebuilt image was made on a BusLogic SCSI
#                              controller (scsi(0)... + ntbootdd.sys). The golden
#                              qcow2 has it rewritten to multi(0)... so NTLDR
#                              reads this IDE disk via INT13h. See docs/guests/nt4.md.
set -e
D=/data/vms/streamhost/stations/nt4
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=()
LOADVM_LABEL="<none: cold boot>"
if qemu-img snapshot -l "$D/nt4-golden.qcow2" 2>/dev/null | grep -qw golden; then
  LOADVM=(-loadvm golden -S)
  LOADVM_LABEL="-loadvm golden"
fi
# Retronet link: create/enslave the vmbr-rn tap (nt4rn0) + arm the guest-
# containment chain BEFORE QEMU opens it (script=no means QEMU attaches to an
# existing tap, it does not create one). Idempotent; runs as root under
# streamhost@ / the golden-bake manual path. Fail-closed: if it cannot verify
# containment it dies here and QEMU never starts. See rn-tapnet.sh + ICQ-STATION-NT4.md.
bash "$D/rn-tapnet.sh" up
# Seed the ICQ nudge's stale-port back to the golden's fixed source port on every
# (re)start: `-loadvm golden` restores the persona onto the golden's port
# regardless of any ephemeral port a previous run drifted to, so a stale portfile
# from a prior reconnect would make the first post-boot nudge miss. Removing it
# falls the healer back to RN_ICQ_GOLDEN_PORT (the golden's port). See
# scripts/retronet/nt4-icq-nudge.py + docs/lab/retronet/ICQ-STATION-NT4.md.
rm -f /run/nt4-icq-port
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup /opt/qemu-cirrusfix2/bin/qemu-system-i386 \
  -L /usr/share/kvm \
  -name streamhost-nt4 \
  -enable-kvm -m 256 -smp 1 \
  -machine pc-i440fx-11.0,hpet=off,vmport=on -cpu pentium3 \
  -rtc base=localtime \
  -device isa-cirrus-vga,global-vmstate=on \
  -drive file=$D/nt4-golden.qcow2,format=qcow2,if=ide \
  -netdev tap,id=n0,ifname=nt4rn0,script=no,downscript=no -device pcnet,netdev=n0,mac=52:54:00:99:00:12 \
  -display dbus,p2p=on \
  "${LOADVM[@]}" \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile nt4 qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54089 loadvm='$LOADVM_LABEL' (golden, no -snapshot)"
