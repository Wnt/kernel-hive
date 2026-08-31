#!/bin/bash
# Launch station 'rhapsody' (slot 146) — Rhapsody 5.1 Developer Release 2 for
# Intel (Apple, 1998): the Platinum Finder on the NeXT/Mach substrate, the
# hinge between the nextstep station and the macos poster.
# See docs/guests/rhapsody.md and docs/lab/research/candidate-rhapsody.md.
#
#   * qemu-system-i386 from /opt/qemu-rhapsody — the kernel-hive QEMU fork
#     (11.0.2 + fast-poll) plus streamhost/qemu-patches/0006-i8259-lenient-
#     spurious-cascade.patch, enabled by KH_I8259_LENIENT_CASCADE=1. Without it
#     Rhapsody's Mach kernel loses every IDE interrupt after the first time the
#     timer and an IDE completion coincide (a spurious IRQ15 it never EOIs on
#     the master): "hc0: interrupt timeout ... Resetting drives". Stock pve-qemu
#     cannot run this guest.
#   * TCG, pentium2, 1 CPU, 64 MB (VOM's confirmed working RAM size; the DR2
#     kernel is known not to boot above 192 MB), i440fx.
#   * ONE IDE disk (rhapsody-golden.qcow2, 2 GB, MBR + Rhapsody UFS) — the
#     device set is deliberately minimal (VOM's shape). Never delete/recreate
#     it: the golden snapshot lives inside it.
#   * Cirrus GD5446 PCI (-vga cirrus; DR2 ships a "Cirrus Logic GD5446 PCI
#     Display Adapter (2MB)" driver — configured for 800x600 RGB:555/16 @60),
#     DEC 21143 "Tulip" PCI (-device tulip) on the retronet (see NETWORK
#     below), PS/2 mouse
#     COM1 = serial.sock (getty on tty00 -> `labctl exec`, kind serial_getty),
#     COM2 = serial.log.
#   * POINTER: ABSOLUTE, with no absolute device and no control loop. Rhapsody
#     keeps its OWN pointer coordinate as a Point{int16 x, int16 y} at
#     guest-physical 0x0050fdac, so `-device kh-ramabs` writes the commanded
#     pixel there and injects one 2-unit relative PS/2 nudge to make the window
#     server republish it (a write alone repaints nothing). The hotspot is never
#     in the path. kh-ramabs holds no vmstate and touches no emulated hardware,
#     so this did NOT change the device set and the golden did NOT need a
#     recapture -- but the ADDRESS IS BOUND TO THE GOLDEN (loadvm restores RAM
#     verbatim), so a re-bake means re-deriving it; see
#     registry/stations/rhapsody.json runtime.qemu.pointerRamAddress. The device
#     verifies the address at connect and REFUSES EVERY WRITE if it cannot, so a
#     stale address degrades to the relative path instead of corrupting memory.
#     SINGLE INJECTOR (binding): while ptr.sock is connected nothing else --
#     no abs->rel bridge, no QMP input-send-event, no labctl pointer helper --
#     may push motion or a button edge at this mouse.
#     Rollback is two lines: drop the -device kh-ramabs line and set
#     SH_INPUT_BACKEND=dbus-rel (with SH_CURSOR_SCALE=2.09) in the fixture. It
#     is two lines ONLY because the fixture still carries SH_REL_MAX_STEP=24 and
#     SH_REL_STEP_PACE_MS=16, which are dead under ramabs and REQUIRED the
#     instant dbus-rel comes back -- without them a visitor's fast drag desyncs
#     this guest's PS/2 driver silently. Do not remove them as unused.
#   * NETWORK: on the retronet, over a tap on the bridge vmbr-rn. The NIC is
#     DEC 21143 "Tulip" (-device tulip), driven by DR2's bundled "DEC Generic
#     21X4X" driver. This REPLACED the install-time Intel EtherExpress PRO/100B
#     (-device i82557b): that pairing is TX-only under QEMU — Apple's Intel82557
#     driver programs the 82557 in flexible mode (RFD + separate receive buffer
#     descriptors), which QEMU's eepro100 model does not implement, so every
#     inbound frame produced "Intel82557: more than 1 rbd, frame size 0" and
#     "en0: resetting adapter" and en0 sat at Ipkts=0 forever. tulip receives.
#     A -device change like this binds only on a COLD boot, as does mac=, so the
#     golden MUST be re-baked cold for either to take. Addressing is STATIC
#     (/etc/iftab): DR2 ships no DHCP client at all, only the BOOTP-era
#     bpwhoami. 10.99.0.22/24, DNS 10.99.0.2 (NetInfo /locations/resolver), and
#     ROUTER=-NO- in /etc/hostconfig so there is NO default route.
#     rn-tapnet.sh is called `up` below on every launch and owns the tap + the
#     fail-closed RHAPRN-IN guard chain. Nothing else rides this netdev — the
#     exec getty is on COM1 and the pointer is PS/2. See
#     docs/lab/retronet/WEB-STATION-rhapsody.md.
#   * -loadvm golden -S when the snapshot exists (frozen at the checkpoint,
#     the daemon wakes it); cold disk boot otherwise (install phase / rebake).
set -e
D=/data/vms/streamhost/stations/rhapsody
QEMU=/opt/qemu-rhapsody/bin/qemu-system-i386
B="$(dirname "$0")"
# The retronet tap + its fail-closed guard chain. Idempotent, and re-asserted on
# EVERY launch so a station relaunch or a host reboot cannot leave the guest on
# the bridge with no containment.
bash "$B/rn-tapnet.sh" up
# Per-station retronet MAC. Unique per station (fleet scheme 52:54:00:52:4e:xx);
# the golden's vmstate carries the MAC, so this only matters on a COLD (re-)bake;
# loadvm golden uses the baked MAC regardless, but this mac= must MATCH it (cold
# boot vs loadvm bind to the same device). Only the one line is read, never the
# whole (secret-bearing) file.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_RHAPSODY_MAC="02:00:00:00:00:16" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_RHAPSODY_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && RN_RHAPSODY_MAC="$_m"
fi
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid" "$D/ptr.sock"
LOADVM=""
qemu-img snapshot -l "$D/rhapsody-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
export KH_I8259_LENIENT_CASCADE=1
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden -S (or vanish on a cold boot)
nohup "$QEMU" \
  -name streamhost-rhapsody \
  -accel tcg -m 64 -smp 1 \
  -machine pc-i440fx-11.0 -cpu pentium2 \
  -rtc base=localtime \
  -drive file=$D/rhapsody-golden.qcow2,format=qcow2,if=ide,index=0 -boot c \
  -vga cirrus \
  -display dbus,p2p=on \
  -netdev tap,id=n0,ifname=rhaprn0,script=no,downscript=no -device tulip,netdev=n0,mac="$RN_RHAPSODY_MAC" \
  -serial unix:$D/serial.sock,server=on,wait=off \
  -serial file:$D/serial.log \
  $LOADVM \
  -chardev socket,id=ptr0,path=$D/ptr.sock,server=on,wait=off \
  -device kh-ramabs,chardev=ptr0,addr=0x0050fdac,layout=point16le,width=1024,height=768,nudge-units=2,nudge-px=1,trace=${PTR_TRACE:-off} \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "station rhapsody qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54146 loadvm='${LOADVM:-<none: cold boot>}'"
