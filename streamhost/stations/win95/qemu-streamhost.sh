#!/bin/bash
# Launch tile 'win95' (VMID 91) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
#
# GOLDEN FIXTURE MODE (resetMode=loadvm, see GOLDEN.md / golden.env / golden.json):
#   * Boots the tile-LOCAL persistent golden disk win95-golden.qcow2 (a copy of the
#     shared gallery image /data/gallery-guests/Win95/win95-osr2-kvm.qcow2, which is
#     left PRISTINE as the backup) with NO -snapshot, so QMP savevm/loadvm can
#     create/restore the live "golden" reset point IN this qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden), so the
#     tile comes up already at the curated fixture (Notepad open+maximized+focused,
#     steady non-blinking caret, screensaver off, taskbar clock hidden, no idle anim).
#     First-ever bake (no snapshot yet) launches cold -- see golden-bake.sh.
#   * NEVER delete win95-golden.qcow2 -- it IS the golden snapshot container.
#   * Wiring matches the pre-golden pilot launcher (KVM, pc,acpi=off,usb=off,
#     kernel-irqchip=off, cpu pentium,-apic, vga std, sb16 audio, pcnet NIC,
#     PS/2 relative kbd+mouse) so the snapshot is portable and the display/audio
#     transport is unchanged. Only the disk (local golden, no -snapshot) differs.
#
# RETRONET BRIDGE (2026-08-21): the pcnet NIC's netdev BACKEND went user->tap on
# vmbr-rn (invisible to savevm/loadvm; the -device pcnet is UNCHANGED, so the
# golden still binds). The guest is static 10.99.0.13/24 with NO default route,
# sharing L2 with the OSCAR gateway CT 10.99.0.2 so ICQ 2000b gets working UDP +
# ICMP + real multi-connection TCP. The warpnet POINTER agent (guest :7777) that
# used to be reached over the slirp hostfwd 127.0.0.1:57791 is now reached
# DIRECTLY over the bridge at 10.99.0.13:7777 (SH_WARPD_ADDR), and a second
# warpnet build (C:\WARPX.EXE, :7788) gives labctl an EXEC channel at
# 10.99.0.13:7788 (the :7777 pointer agent's serial accept loop is monopolised by
# the daemon's persistent pointer connection, so exec needs its own port). A
# UNIQUE MAC is pinned (see the RN_WIN95_MAC block below). See
# docs/lab/retronet/ICQ-STATION-win95.md.
set -e
D=/data/vms/streamhost/stations/win95
DISK="$D/win95-golden.qcow2"
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# Retronet link: create/enslave the vmbr-rn tap (win95rn0) + arm the guest-
# containment chain BEFORE QEMU opens it (script=no means QEMU attaches to an
# existing tap, it does not create one). Idempotent; runs as root under
# streamhost@ / the golden-bake manual path. Fail-closed: if it cannot verify
# containment it dies here and QEMU never starts. See rn-tapnet.sh + ICQ-STATION-win95.md.
bash "$D/rn-tapnet.sh" up
# Seed the ICQ nudge's stale-port back to the golden's fixed source port on every
# (re)start: `-loadvm golden` restores the persona onto the golden's port
# regardless of any ephemeral port a previous run drifted to, so a stale portfile
# from a prior reconnect would make the first post-boot nudge miss. Removing it
# falls the healer back to RN_ICQ_GOLDEN_PORT (the golden's port). See
# scripts/retronet/win95-icq-nudge.py + docs/lab/retronet/ICQ-STATION-win95.md.
rm -f /run/win95-icq-port
# Guest NIC MAC. Real per-station MACs are NEVER committed (AGENTS.md); the real
# value lives in gitignored registry/local.env as RN_WIN95_MAC (retronet fleet
# scheme 52:54:00:52:4e:<last-IP-octet>, "52:4e"=RN, .13 -> ...0d) so every
# bridged guest is L2-distinct. The golden's vmstate carries the MAC, so this
# only matters on a COLD (re-)bake; loadvm golden uses the baked MAC regardless.
# Only the one line is read, never the whole (secret-bearing) file.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_WIN95_MAC="02:00:00:00:00:0d" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_WIN95_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && RN_WIN95_MAC="$_m"
fi
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-win95 \
  -enable-kvm -m 256 -smp 1 \
  -machine pc,acpi=off,usb=off,kernel-irqchip=off,accel=kvm -cpu pentium,-apic \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -drive file="$DISK",format=qcow2,if=ide -netdev tap,id=n0,ifname=win95rn0,script=no,downscript=no -device pcnet,netdev=n0,mac="$RN_WIN95_MAC" \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile win95 qemu pid=$(cat $D/qemu.pid 2>/dev/null) qmp=$D/qmp.sock udp=54091 loadvm='${LOADVM:-<none: cold boot>}' (golden, no -snapshot)"
