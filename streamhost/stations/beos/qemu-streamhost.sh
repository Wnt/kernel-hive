#!/bin/bash
# Launch tile 'beos' (VMID 143) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# BeOS R5 Professional 5.0.3 (Be Inc., 2000) — the original behind the haiku
# station. Native x86 on the i440fx PC machine, but under TCG: the R5 kernel
# takes #GP under KVM (idle-thread trap 0d with pentium2/pentium3, a later hang
# with qemu32 — unhandled MSR reads that TCG returns 0 for). Pentium III class,
# one CPU, 512 MB (R5 caps RAM well below 1 GB). PS/2 keyboard + mouse: R5 has
# no absolute-tablet driver; the pointer is driven relative through browser
# pointer-lock (pointerRel, the qnx pattern).
# std VGA is R5's "unsupported card" VESA stub at the vesa-settings mode
# 1024x768x16. NIC: rtl8139, driven by R5's own `rtl8139` driver -- NOT the
# ne2k_pci this station shipped with until 2026-08-23. ne2k_pci works fine while
# the link is idle, but under real traffic (a corpus page full of images) R5's
# `etherpci` driver loses the NE2000 receive ring and storms
# `etherpci_read: bad next packet!` -- 144,683 of them in one page load -- until
# the NIC is dead, the guest's MAC has aged out of the bridge FDB and QEMU is
# pegged at 100% CPU. It is a load-dependent bug: the same page loaded cleanly on
# a rig with -display none (more CPU for the guest) and killed the link every
# time under the production capture path. See docs/lab/retronet/STATION-beos.md.
# NO audio device: both
# QEMU AC97 (R5 i801 driver) and ES1370 (es137x) stall the guest the moment the
# media_server opens them under TCG — open item in docs/guests/beos.md. See docs/guests/beos.md
# for the two blockers that had to be fixed INSIDE the volume (config_manager/isa
# removed; multiprocessor_support disabled so PCI IRQs route through the PIC).
#
# GOLDEN FIXTURE MODE (resetMode=loadvm):
#   * Boots the persistent tile-LOCAL golden qcow2 (NO -snapshot) so QMP
#     savevm/loadvm can create/restore the live "golden" reset point IN it. The
#     disk is a standalone qcow2 (no backing dep), a curated copy of the
#     installed volume which stays untouched at
#     /data/gallery-guests/Beos/beos-r5.qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden -S,
#     frozen at the fixture until the daemon resumes it). The first-ever bake
#     (no snapshot yet) launches cold.
#
# RETRONET BRIDGE (2026-08-22): n0 is a real bridged NIC on vmbr-rn, NOT slirp.
# rn-tapnet.sh (called `up` just below, idempotently, exactly like
# win98se/rn-tapnet.sh and solaris/rn-tapnet.sh) creates the persistent tap
# beosrn0, enslaves it to vmbr-rn, and installs a fail-closed guest-containment
# chain -- and FAILS THE LAUNCH if that chain does not verify, so QEMU never
# starts an uncontained guest. The guest is a DHCP client with a reservation on
# 10.99.0.16/24 and NO default route (retronet-dhcp withholds option 3), and it
# shares L2 with the gateway CT 10.99.0.2, so NetPositive resolves every name to
# the gateway and reads the museum corpus from its :80 origin. The -device is
# UNCHANGED (ne2k_pci, netdev=n0) -- only the netdev backend went user->tap,
# which is invisible to savevm/loadvm, so `loadvm golden` stays valid ON A
# TAP-NATIVE golden. (The pre-swap slirp golden does NOT loadvm on the tap; a
# fresh tap-native golden was cold-baked 2026-08-22 -- see
# docs/lab/retronet/STATION-beos.md.)
#
# EXEC CHANNEL rides the same bridge: BeOS R5's own telnetd, reached by labctl
# at 10.99.0.16:23 (exec_kind beos_telnet). It is labhost-INITIATED, so its
# replies pass the guard chain as ESTABLISHED while every NEW flow the guest
# starts toward labhost stays dropped.
set -e
D=/data/vms/streamhost/stations/beos
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/beos-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# Retronet link: create/enslave the vmbr-rn tap + arm the guest-containment
# chain BEFORE QEMU opens it (script=no means QEMU attaches to an EXISTING tap,
# it does not create one). Idempotent; runs as root under streamhost@ and the
# bring-up manual path alike. Fail-closed under `set -e`: if it cannot verify
# containment it exits non-zero and QEMU never starts.
bash "$D/rn-tapnet.sh" up
# UNIQUE per-station MAC on vmbr-rn. The whole QEMU fleet otherwise boots QEMU's
# one default MAC, and two of them on one bridge collapse to a single FDB entry --
# unicast flaps between taps and per-MAC DHCP reservations collide. The real
# per-station value is box-local (registry/local.env RN_BEOS_MAC, gitignored, on
# the retronet MAC scheme 52:4e:<last IP octet>); the committed fallback below is
# a scrubbed placeholder. The MAC is ALSO baked into the golden's device vmstate --
# loadvm restores THAT regardless of this mac=, so the golden was cold re-baked
# with it and this mac= must MATCH (cold boot vs loadvm agreement). See
# docs/lab/retronet/STATION-beos.md and WEB-PROXY.md.
RN_BEOS_MAC="02:00:00:00:00:10" # placeholder (committed); real value from local.env
RN_LOCAL_ENV=/data/kernel-hive/registry/local.env
if [ -f "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^[[:space:]]*RN_BEOS_MAC=//p' "$RN_LOCAL_ENV" | tail -1 | tr -d '\042\047')"
  [ -n "$_m" ] && RN_BEOS_MAC="$_m"
fi
# EXEC-CHANNEL PASSWORD. `labctl exec beos` logs into R5's own telnetd as
# $RN_BEOS_EXEC_USER, and the password must NOT live in the committed registry,
# so the launcher republishes it from the gitignored local.env into the station
# dir on every start (same rule and shape as rhapsody's serial-exec.passwd).
# Written 0600 and root-owned; labctl reads it, nothing else does.
_bp="$(sed -n 's/^[[:space:]]*RN_BEOS_EXEC_PASS=//p' "$RN_LOCAL_ENV" 2>/dev/null | tail -1 | tr -d '\042\047')"
if [ -n "$_bp" ]; then
  (
    umask 077
    printf '%s\n' "$_bp" >"$D/telnet-exec.passwd"
  )
fi
unset _bp
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-beos \
  -accel tcg -m 512 -smp 1 \
  -machine pc-i440fx-11.0 -cpu pentium3 \
  -rtc base=localtime \
  -drive file=$D/beos-golden.qcow2,format=qcow2,if=ide,index=0 -boot c \
  -vga std \
  -display dbus,p2p=on \
  -netdev tap,id=n0,ifname=beosrn0,script=no,downscript=no -device rtl8139,netdev=n0,mac="$RN_BEOS_MAC" \
  -serial file:$D/serial.log \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile beos qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54143 loadvm='${LOADVM:-<none: cold boot>}' (golden, no -snapshot)"
