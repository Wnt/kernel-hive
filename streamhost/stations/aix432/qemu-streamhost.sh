#!/bin/bash
# Launch station 'aix432' (slot 171) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# IBM AIX 4.3.3 with CDE on an emulated IBM RS/6000 7020 (40p), PowerPC 604 —
# the fleet's first PReP/PowerPC station, in the hpuxvue/macos753 mould.
#
# --------------------------------------------------------------------------
# READ docs/lab/research/candidate-aix.md BEFORE CHANGING ANYTHING HERE.
# --------------------------------------------------------------------------
#
# THE BINARY IS NOT pve-qemu. The fleet package ships no usable ppc/40p target
# and, more to the point, upstream QEMU's 40p has NO display an RS/6000 guest
# can drive. This station runs a standalone build of the kernel-hive QEMU fork
# (github.com/Wnt/qemu, branch aix432-s3) installed at /opt/qemu-ppc-s3, which
# carries, all written for this station:
#   * hw/display/mga.c  — a Matrox MGA G200 model standing in for IBM's GXT130P
#     (-vga mga). AIX 4.3 drives NO adapter upstream QEMU emulates; this is the
#     only reason X and CDE render at all.
#   * a PS/2 scancode-set-3 fix (SET_MAKE_BREAK takes a key LIST, not one byte)
#     without which every /dev/lft0 open fails and there is no console.
#   * the PREP_TB_FREQ timebase override, below.
#   * Herve Poussineau's S3 Trio card (-vga s3) — present in the binary but
#     DELIBERATELY NOT USED here; see the -vga note below.
# Rebuild:
#   ../configure --target-list=ppc-softmmu --enable-slirp --enable-dbus-display \
#     --disable-opengl --disable-werror --disable-tools --prefix=/opt/qemu-ppc-s3
#   ninja qemu-system-ppc && ninja install
#
# TCG, NO KVM. PowerPC has no acceleration path on this host, so the station
# burns a host core whenever the guest runs; SH_IDLE_PAUSE_SECS matters here.
#
# PREP_TB_FREQ=15000000 IS NOT OPTIONAL ON A COLD BOOT. The genuine IBM 40p ROM
# assumes a 15 MHz timebase (66.67 ns/tick constants) where QEMU offers 100 MHz;
# without the override POST's clock arithmetic goes negative and the firmware
# halts in an LED-flash loop displaying 888-102-700-0A5. It is exported for the
# loadvm path too so that both shapes run the identical machine configuration.
#
# -vga mga AND NOTHING ELSE — this is load-bearing and easy to "fix" wrongly.
# The bring-up rigs ran `-vga s3 -device mga,id=mga0`, giving Open Firmware a
# console on the S3 and AIX a GXT130P on the Matrox. That arrangement CANNOT be
# used here: the streamhost daemon addresses the guest display at the hardcoded
# dbus path /org/qemu/Display1/Console_0 for BOTH capture and input injection
# (streamhost/src/capture/mod.rs), and with an S3 present the S3 is console 0
# and the Matrox — the surface AIX actually paints CDE on — is console 1. With
# `-vga mga` the Matrox IS console 0 and the greeter/desktop is what gets
# streamed. The cost is that the firmware has no card it can paint on, so the
# framebuffer stays "Guest has not initialized the display (yet)" until AIX's
# own LFT driver lights the Matrox. That is expected, not a fault.
#
# THE POINTER IS A CLOSED LOOP, and the chardev below is what closes it. The
# 40p has a PS/2 mouse and no absolute device of any kind, so this station used
# to reckon absolute coordinates by dead reckoning (SH_INPUT_BACKEND=dbus-rel)
# -- pin the cursor into a corner once, then push deltas from a belief that
# guest acceleration, an edge clamp or an X warp silently invalidates. It does
# not have to. AIX's GXT130P X server drives the emulated Matrox HARDWARE
# cursor, so the guest writes its own pointer position into the DAC's CURPOSX/Y
# registers and hw/display/mga.c reads them back: the engine there converges on
# the MEASUREMENT, exactly as irix's MOVEA engine converges on the Newport VC2
# registers inside MAME (docs/IO-PATHS.md). `-global mga.ptrctl=ptr0` hands the
# device the control socket the daemon speaks mgaptr/1 over; drop it and the
# device behaves exactly as it did before the engine existed -- no timer, no
# handlers, no injection -- which is also the rollback (pair it with
# SH_INPUT_BACKEND=dbus-rel in station.env.fixture, and nothing else changes).
#
# SINGLE INJECTOR (BINDING). While that socket is connected the engine owns
# this guest's pointer. Nothing else may push motion or button edges at the
# mouse -- not the dbus-rel bridge, not `input-send-event` over QMP, not a
# labctl pointer helper -- or the two injectors fight over the guest's PS/2
# accumulator and neither knows where the cursor is. Keys are unaffected: they
# still ride the ordinary QEMU/dbus keyboard path.
#
# NO BOOTABLE MEDIA IN THE CD DRIVE, EVER. The CD is nicdrv.iso, a 660 KB
# NON-bootable ISO holding the two ethernet filesets. Attaching the real AIX
# 4.3.3 Volume 1 install disc here instead makes the machine boot THAT and trap
# the kernel ("Illegal Trap Instruction Interrupt in Kernel", a divide-by-zero
# guard on a clock frequency) about two minutes in. The drive is kept populated
# and attached in every shape so the device set does not change between a cold
# boot and a loadvm — `loadvm` requires an identical device set — and so a
# future fileset install needs no device change and therefore no re-bake.
#
# RETRONET: ent0 is a real bridged NIC on vmbr-rn, not slirp. rn-tapnet.sh
# (called `up` just below, idempotently) creates the persistent tap aixrn0,
# enslaves it to vmbr-rn and installs a fail-closed guest-containment chain.
# WEB PLANE ONLY — there is no OSCAR client on this guest, so it never joins
# the icq plane. The guest is STATIC 10.99.0.28/24, DNS 10.99.0.2, and has NO
# default route by construction (only the on-link 10.99/24 route and loopback).
# The NIC model is NOT free: AIX 4.3.3 ships drivers for no NIC QEMU emulates
# except the AMD PCnet, which its `devices.pci.22100020` fileset ("IBM PCI
# Ethernet Adapter", 0x1022:0x2000) drives — and which is also -M 40p's own
# default_nic. romfile= is empty because this standalone prefix ships no x86
# option ROMs and a PReP guest never executes one.
#
# TWO LAUNCH SHAPES, decided by what exists in the disk:
#   1. golden snapshot present -> -loadvm golden -S (the exhibit; frozen at the
#      CDE desktop until the first visitor). A restore does NOT walk the
#      firmware POST and does NOT need skipfix at all.
#   2. no snapshot -> COLD boot, which DOES walk the genuine ROM's POST and
#      therefore needs the skipfix gdb helper armed against -gdb (below).
# The device set is IDENTICAL in both.
set -e
D=/data/vms/streamhost/stations/aix432
A=/data/vms/streamhost/assets/aix432
QEMU=/opt/qemu-ppc-s3/bin/qemu-system-ppc
DISK=$D/aix432-golden.qcow2
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid" "$D/serial.sock" "$D/gdb.sock" "$D/ptr.sock"
LOADVM=""
if qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden; then
  LOADVM="-loadvm golden -S"
fi
# Retronet link: create/enslave the vmbr-rn tap + arm the guest-containment
# chain BEFORE QEMU opens it (script=no means QEMU attaches to an existing tap,
# it does not create one). Idempotent. Fail-closed: if it cannot verify
# containment it dies here under `set -e` and QEMU never starts.
bash "$D/rn-tapnet.sh" up
# Guest NIC MAC. Real per-station MACs are NEVER committed (AGENTS.md rule 1);
# the real value lives in gitignored registry/local.env as RN_AIX432_MAC
# (the fleet's retronet MAC scheme is recorded alongside it there, not here,
# because scheme plus octet reconstructs the address). The
# golden's vmstate carries the MAC, so this only matters on a COLD (re-)bake;
# loadvm golden uses the baked MAC regardless, but this mac= must MATCH it.
# Only the one line is read, never the whole (secret-bearing) file.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_AIX432_MAC="02:00:00:00:00:1c" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_AIX432_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && RN_AIX432_MAC="$_m"
fi
# streamhost display fast-poll: dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into flags
nohup env PREP_TB_FREQ=15000000 "$QEMU" \
  -name streamhost-aix432 \
  -M 40p,audiodev=snd0 -audiodev none,id=snd0 \
  -global cs4231a.dma=6 \
  -bios $A/rs6k40p.BIN -m 192 \
  -drive file=$DISK,format=qcow2,if=scsi,bus=0,unit=0,cache=writeback,aio=threads \
  -drive file=$A/nicdrv.iso,format=raw,if=scsi,bus=0,unit=2,media=cdrom,readonly=on \
  -vga mga \
  -chardev socket,id=ptr0,path=$D/ptr.sock,server=on,wait=off \
  -global mga.ptrctl=ptr0 \
  -netdev tap,id=n0,ifname=aixrn0,script=no,downscript=no \
  -device pcnet,netdev=n0,mac="$RN_AIX432_MAC",romfile= \
  -display dbus,p2p=on \
  -serial unix:$D/serial.sock,server=on,wait=off \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -gdb unix:$D/gdb.sock,server=on,wait=off \
  $LOADVM \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
# Cold boot only: the genuine ROM's POST calls settimeofday once, and its 604
# fallback path poisons the clock offset into the 888-102-700-0A5 halt. skipfix
# attaches to the gdb stub and steps over that single `bl`. A loadvm restore
# never executes POST, so this is deliberately NOT armed on the exhibit path.
if [ -z "$LOADVM" ]; then
  nohup python3 "$D/skipfix.py" "$D/gdb.sock" >"$D/skipfix.log" 2>&1 &
fi
echo "station aix432 qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54171 loadvm='${LOADVM:-<none>}'"
