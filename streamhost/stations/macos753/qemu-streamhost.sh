#!/bin/bash
# Launch station 'macos753' (slot 142) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# Mac OS 7.5.3 on a Motorola 68040 Quadra 800 — the fleet's FIRST
# foreign-architecture QEMU station. Everything unusual about this launcher
# follows from that.
#
# THE BINARY IS NOT pve-qemu. The fleet package ships x86_64/i386/arm/aarch64
# and no m68k target at all, so this station runs a standalone build of the
# kernel-hive QEMU fork (github.com/Wnt/qemu, branch kernel-hive) installed at
# /opt/qemu-m68k — the same arrangement nt4 uses for its Cirrus-fix build. The
# usual objection to a non-pve binary is that it cannot `loadvm` a checkpoint
# carrying pve's pbs-state vmstate section; it does not apply here, because this
# station's checkpoint is baked AND restored by this binary and never contains
# that section. Rebuild it whenever the fork moves:
#   ../configure --target-list=m68k-softmmu --enable-slirp --enable-dbus-display \
#     --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice \
#     --disable-opengl --disable-werror --disable-tools --prefix=/opt/qemu-m68k
#
# TCG, NO KVM. m68k has no hardware acceleration path, so this station burns
# real host CPU whenever it runs. That is why it starts PAUSED (-S) at the
# checkpoint and leans on idle auto-pause: an unwatched station costs ~0.
#
# THE PRAM IS A qcow2, NOT RAW, and that is load-bearing. A raw `if=mtd` drive
# makes `savevm` refuse outright — "Device 'mtd0' is writable but does not
# support snapshots" — so the whole checkpoint plane depends on this one flag.
# The PRAM also carries the boot device (offset 120) and the mouse-tracking
# setting the 1:1 pointer calibration depends on; it is fixture state, not
# scratch, and is restored from the checkpoint like everything else.
#
# THE RETRONET NIC — dp83932 (SONIC), and there was never a choice to make.
# `-M q800 -nic model=help` lists exactly ONE model: dp8393x (aka dp83932), the
# Quadra 800's real built-in Apple Ethernet. So unlike every other station on the
# bridge this one could not pick a card to suit the guest's driver set — the
# machine has the card the real machine had, and Mac OS 7.5.3 drives it out of
# the box: MacTCP's driver list shows "Ethernet" beside LocalTalk on the first
# cold boot, with nothing installed into the guest.
#
# Adding it CHANGED THE DEVICE SET, and `loadvm golden` binds to exactly that
# set, so the golden was COLD RE-BAKED from scratch on 2026-08-23 (the chokanji
# pattern). Note this machine keeps its vmstate in the PRAM qcow2, not the disk
# — see the PRAM paragraph above — so the pair is what carries the checkpoint.
# The pre-change disk+PRAM pair is kept next to the live images; see
# docs/lab/retronet/WEB-STATION-macos753.md.
#
# STATIC addressing, not DHCP: the guest's stack is MacTCP 2.0.6, whose "Obtain
# Address" choices are Manually / Server (BOOTP-RARP) / Dynamically — there is no
# DHCP in it at all. It is configured by hand on its reserved address
# 10.99.0.23, DNS 10.99.0.2, and its Gateway Address left 0.0.0.0 so the guest
# has NO default route. The 10.99.0.23 DHCP reservation exists only to keep the
# address unique on the plane and is never claimed.
#
# AUDIO IS NOT OPTIONAL. `-M q800` instantiates the Apple Sound Chip and QEMU
# REFUSES TO START without an audiodev bound to the machine
# ("Initializing audio stream failed"), so `audiodev=snd0` on -M is required
# even though the audio itself rides the dbus display.
#
# POINTER: ADB relative. There is no absolute pointer path on this machine at
# all — no USB bus, no tablet — so the daemon runs SH_INPUT_BACKEND=dbus-rel and
# converts absolute client coordinates into deltas. The guest moves 0.36 px per
# delta unit (Mouse control panel at "Very Slow", the only non-accelerated
# setting), hence SH_CURSOR_SCALE=2.7778 in the emitted station.env.
#
# CHECKPOINT MODE (resetMode=loadvm, see GOLDEN.md):
#   * Boots the persistent station-LOCAL qcow2 pair (NO -snapshot) so QMP
#     savevm/loadvm can create/restore the live "golden" reset point IN them.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden -S)
#     so the station comes up already at the quiet Finder desktop, frozen until
#     the first visitor arrives. The first-ever bake launches cold.
set -e
D=/data/vms/streamhost/stations/macos753
# Bring the retronet link up BEFORE QEMU opens it (script=no means QEMU attaches
# to an EXISTING tap, it does not create one). Idempotent, so it runs on every
# start under streamhost@ and on the manual golden-bake path alike. FAIL-CLOSED:
# if the containment chain does not verify, this dies here and QEMU never starts.
bash "$D/rn-tapnet.sh" up
# Guest NIC MAC. Real per-station MACs are NEVER committed (AGENTS.md); the real
# value lives in gitignored registry/local.env as RN_MACOS753_MAC. This guest
# forces the Apple OUI 08:00:07 — the SONIC's address is read back by Mac OS as
# the machine's Ethernet ID, so the retronet's usual 52:54:00:52:4e:<octet>
# scheme does not apply here. The golden's vmstate carries the MAC, so this only
# matters on a COLD (re-)bake, but cold boot and loadvm bind to the same device
# and this mac= MUST match the baked one. Only the one line is read, never the
# whole (secret-bearing) file.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_MACOS753_MAC="02:00:00:00:00:17" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_MACOS753_MAC=//p' "$RN_LOCAL_ENV" | head -1 | tr -d '"')"
  [ -n "$_m" ] && RN_MACOS753_MAC="$_m"
fi
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/macos753-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll: dbus poll every SH_DBUS_UPDATE_MS ms. The patch
# is in the fork this binary is built from, and its run-state idle gate is what
# keeps a paused TCG station at ~0 cost.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden -S (or vanish on a cold boot)
nohup /opt/qemu-m68k/bin/qemu-system-m68k \
  -name streamhost-macos753 \
  -accel tcg -m 128 \
  -M q800,audiodev=snd0 -cpu m68040 \
  -bios /data/vms/streamhost/assets/macos753/800.ROM \
  -g 1152x870x8 \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -drive file=$D/pram-golden.qcow2,format=qcow2,if=mtd \
  -device scsi-hd,scsi-id=6,drive=hd0 \
  -drive file=$D/macos753-golden.qcow2,format=qcow2,cache=writeback,aio=threads,if=none,id=hd0 \
  -nic tap,ifname=macosrn0,script=no,downscript=no,model=dp83932,mac="$RN_MACOS753_MAC" \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "station macos753 qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54142 loadvm='${LOADVM:-<none: cold boot>}' (checkpoint, no -snapshot)"
