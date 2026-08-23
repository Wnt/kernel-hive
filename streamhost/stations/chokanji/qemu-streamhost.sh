#!/bin/bash
# Launch station 'chokanji' (VMID 149) QEMU with the streamhost display wiring.
#
# Chokanji / 超漢字 — B-right/V, the commercial BTRON3 desktop from Ken
# Sakamura's TRON project. This is a disk-backed guest: the IDE disk
# (chokanji.qcow2 = the whole machine) is qcow2, so the live `savevm golden`
# VM-state snapshot is stored INSIDE that base qcow2 disk. resetMode=loadvm
# (see station.env.fixture).
#   * Runs WITHOUT -snapshot so `savevm golden` PERSISTS into the qcow2 disk.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden -S),
#     so the station comes up already at the curated BTRON desktop, FROZEN
#     (~0 CPU); the first visitor session's cont (idle.rs) wakes it sub-second.
#     A first-ever bake (no snapshot yet) cold-boots RUNNING for the bake driver.
#
# DEVICE SET — do NOT change it; `loadvm golden` binds to exactly this set.
#   * KVM accel, -machine pc-i440fx-11.0 -cpu host, 256 MB (the amount the
#     B-right/V build in this disk was tuned for), std i8042 PS/2 keyboard.
#   * vmport=off is LOAD-BEARING. The disk was originally a VMware guest, so
#     QEMU's default VMware I/O port makes the `vmmouse` device the current
#     pointer and it SWALLOWS all injected motion — the BTRON hand cursor never
#     moves (query-mice shows vmmouse current, absolute=false; BTRON does not
#     poll the VMware port, so vmmouse never reaches absolute mode). Turning
#     vmport off removes vmmouse; the default i8042 PS/2 mouse then becomes the
#     live pointer and BTRON tracks it. (The Virtual OS Museum reaches the same
#     conclusion for B-right/V: run it with vmport off.)
#   * PS/2 RELATIVE pointer (default i8042 mouse, no -device): BTRON's driver is
#     a plain relative mouse, so SH_POINTER=rel and the UI pointerRel=true feed
#     browser Pointer Lock 1:1 deltas. usb-tablet (absolute) does NOT move the
#     cursor on this guest; PS/2 relative works once vmmouse is out of the way.
#   * -vga cirrus: the BTRON screen driver in this disk drives the Cirrus
#     GD5446 at 800x600. (std VGA renders black — the driver is Cirrus-specific.)
#   * RETRONET BRIDGE (2026-08-23): rtl8139 on vmbr-rn — a real bridged NIC, not
#     slirp. The model is not a guess: qemuckj/q.bat, the launch script the
#     original packagers shipped ALONGSIDE this very mc.img, reads
#     `-net nic,model=rtl8139`, and pxe-rtl8139.bin is the only NIC ROM in that
#     port. B-right/V's driver set is narrow and this is the card it expects.
#     Adding the device CHANGED the device set, so the golden was cold re-baked
#     from scratch on 2026-08-23 (loadvm binds to the exact set); the pre-change
#     disk+golden pair is kept, see docs/lab/retronet/WEB-STATION-chokanji.md.
#     rn-tapnet.sh (called `up` just below, idempotently, like win98se's) creates
#     the persistent tap chokanjirn0, enslaves it to vmbr-rn and installs a
#     fail-closed containment chain. Adding the PCI NIC did NOT disturb the
#     vmmouse trap above — PS/2 is still the current pointer (query-mice).
#     `romfile=` DISABLES the card's PXE option ROM on purpose. It is not
#     cosmetic: the ROM is a migratable ramblock, and a golden baked with it
#     present refuses to load on a machine where it is absent
#     ("Unknown ramblock 0000:00:03.0/rtl8139.rom, cannot accept migration") —
#     which cost one bake. This guest boots from its IDE disk and never PXE-boots,
#     so the ROM is dead weight; pinning it off makes the device set the golden
#     binds to independent of option-ROM discovery. Bake and run MUST agree.
#   * STATIC addressing, not DHCP: B-right/V 4.202's ネットワーク設定 panel is
#     static-only (its sole アドレス tab has no DHCP option) and the guest emits
#     no DISCOVER at boot — this stack has no DHCP client. The guest is configured
#     by hand on its reserved address 10.99.0.21/24, DNS 10.99.0.2, and the
#     ゲートウェイ「使用する」box is deliberately left UNCHECKED, which is what
#     gives it no default route (the same no-WAN posture the DHCP reservation
#     encodes for the other retronet stations).
#   * NO audio device yet: the BTRON desktop is effectively silent; SB16 (what
#     the original QEMU-CKJ q.bat used, alongside that rtl8139) is a future add.
# Kill only by pidfile. Full rationale + media provenance: docs/guests/chokanji.md.
set -e
B=/data/vms/streamhost/stations/chokanji
DISK=/data/gallery-guests/Chokanji/chokanji.qcow2
# Bring the retronet tap up and install the fail-closed guest-containment chain
# BEFORE QEMU opens it (script=no means QEMU attaches to an EXISTING tap, it does
# not create one). Idempotent; runs as root under streamhost@ and the manual
# golden-bake path alike. Fail-closed: if containment does not verify it dies
# here and QEMU never starts.
bash "$B/rn-tapnet.sh" up
# Guest NIC MAC. Real per-station MACs are NEVER committed (AGENTS.md); the real
# value lives in gitignored registry/local.env as RN_CHOKANJI_MAC (retronet fleet
# scheme 52:54:00:52:4e:<last-IP-octet>, "52:4e"=RN, .21 -> ...15) so every
# bridged guest is L2-distinct and per-MAC DHCP reservations do not collide.
# chokanji is statically addressed in-guest, but it still holds a reservation so
# nothing else can be handed 10.99.0.21. The golden's vmstate carries the MAC, so
# this only matters on a COLD (re-)bake; loadvm golden uses the baked MAC
# regardless, but this mac= must MATCH it (cold boot and loadvm bind to the same
# device). Only the one line is read, never the whole (secret-bearing) file.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_CHOKANJI_MAC="02:00:00:00:00:15" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_CHOKANJI_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && RN_CHOKANJI_MAC="$_m"
fi
[ -f "$B/qemu.pid" ] && kill "$(cat "$B/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$B/qmp.sock" "$B/qemu.pid"
# Boot straight into the curated fixture if the golden snapshot is already
# present inside the disk; otherwise cold-boot RUNNING for a first-ever bake.
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost QEMU display-capture fast-poll (pve-qemu 0047 patch): dbus display
# polls every SH_DBUS_UPDATE_MS ms (default 4; clamp 1..29; 0/unset = stock 30 ms).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden -S (or vanish on a cold boot)
nohup qemu-system-x86_64 \
  -name streamhost-chokanji \
  -enable-kvm -m 256 -smp 1 \
  -machine pc-i440fx-11.0,vmport=off -cpu host \
  -rtc base=localtime \
  -boot c \
  -vga cirrus \
  -display dbus,p2p=on \
  -drive file="$DISK",format=qcow2,if=ide \
  -netdev tap,id=rn0,ifname=chokanjirn0,script=no,downscript=no \
  -device rtl8139,netdev=rn0,mac="$RN_CHOKANJI_MAC",romfile= \
  $LOADVM \
  -qmp unix:"$B/qmp.sock",server=on,wait=off \
  -pidfile "$B/qemu.pid" \
  >"$B/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$B/qmp.sock" ] && [ -f "$B/qemu.pid" ] && break
  sleep 0.5
done
echo "station chokanji qemu pid=$(cat "$B/qemu.pid" 2>/dev/null) qmp=$B/qmp.sock udp=54149 loadvm='${LOADVM:-<none: cold boot>}'"
