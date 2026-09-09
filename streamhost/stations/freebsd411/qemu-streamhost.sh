#!/bin/bash
# freebsd411 — FreeBSD 4.11-RELEASE i386 (Jan 2005), KDE 3.3.2 on XFree86 4.4.0 (vesa driver on -vga std).
# Scaffolded from netbsd14 (pc-i440fx-11.0 KVM) on 2026-09-02, then measured (golden stream, 2026-09-03):
#   * the system disk is a SCSI disk on an lsi53c895a (FreeBSD `sym`), NOT IDE: 4.11's ata driver
#     refuses bus-master DMA on QEMU's PIIX3 ("atapci0: Busmastering DMA not supported",
#     "ad0 ... BIOSPIO") and 16-bit PIO under KVM is one exit per word — ~150 KB/s disk I/O.
#     The `sym` path does real DMA; the guest's /etc/fstab names da0s1*.
#   * -vga std: XFree86 4.4.0 vesa at 1024x768x16 (the cirrus route was never needed).
# pointer MOTION is absolute through the guest X server (SH_INPUT_BACKEND=x11warp on
# SH_X11WARP_DISPLAY=127.0.0.1:78 via the loopback SLIRP forward 6078->6000 below),
# buttons + keys ride the D-Bus PS/2 path.
#
# The station is on the retronet (2026-09-03): a second, BRIDGED NIC (e1000 -> em0) on vmbr-rn
# carries the ICQ plane (Kopete 0.9.1 -> the gateway's OSCAR door 10.99.0.2:5190)
# and the web plane (Konqueror -> the gateway's :80 corpus origin, seamless, no
# proxy). docs/lab/retronet/STATION-freebsd411.md.
#
# disk.qcow2 is the ONLY block device and carries the 'golden' vmstate. Baked
# under /opt/qemu-beos (QEMU 11.0.2 fork, same machine types as the host pve
# build): golden + binary + device set are ONE combination (rule 6).
set -e
BASE=/data/vms/streamhost/stations/freebsd411
DISK="$BASE/disk.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
[ -f "$DISK" ] || cp /data/gallery-guests/FREEBSD411/freebsd411.qcow2 "$DISK"
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# Retronet: the SECOND NIC is a real bridged tap on vmbr-rn. OSCAR cannot
# traverse slirp, so the ICQ plane needs L2; the web plane rides the same NIC
# (DHCP-reserved 10.99.0.35, DNS 10.99.0.2, no default route).
#
# e1000 (guest `em0`), NOT rtl8139 — MEASURED 2026-09-03. The NIC was first
# baked as an rtl8139 because `rl` does real DMA where the ne2k path is one KVM
# exit per 16-bit word. It works on a cold boot and then dies at the only moment
# that matters: 4.11's rl(4) NEVER TRANSMITS AGAIN AFTER A vmstate RESTORE. After
# `-loadvm golden` the guest's rl0 still holds 10.99.0.35 and its routes are
# right, but not one frame reaches the tap — tcpdump on freebsd411rn0 stays
# silent while the guest pings 10.99.0.2 and the bridge fdb never learns the MAC.
# `ifconfig rl0 down; ifconfig rl0 up` in the guest and QMP set_link off/on do
# not revive it; Linux guests on the same rtl8139 transmit fine after a restore,
# so this is 4.11's rl(4) against the restored device state, not QEMU. em(4)
# reprograms its rings from scratch and transmits immediately: proven on a clone
# by cold boot -> savevm -> quit -> `-loadvm golden -S` -> cont -> ping answered
# with the guest's own frames captured on the tap
# (evidence/retronet-e1000-golden-restore-proof.png). em0 is in 4.11 GENERIC,
# does DMA, and `ifconfig_em0=DHCP` in the guest's /etc/rc.conf takes the same
# reserved address. Rule 6: this device set and the golden are ONE combination —
# the rtl8139-era golden does not restore against e1000, hence the 2026-09-03
# 09:58:56 re-bake (see station.env.fixture). The slirp NIC above stays exactly as it was, purely as the x11warp
# pointer path. rn-tapnet.sh creates the tap and installs the fail-closed
# FREEBSD411RN-IN guard chain on EVERY start, under `set -e`: QEMU never starts
# an uncontained guest. The MAC lives in the golden's device vmstate.
RN_MAC="$(sed -n 's/^[[:space:]]*RN_FREEBSD411_MAC=//p' /data/kernel-hive/registry/local.env 2>/dev/null | tail -1 | tr -d '"'"'"'"')"
RN_MAC="${RN_MAC:-02:00:00:00:00:23}"
"$BASE/rn-tapnet.sh" up

# `restrict=on` on the slirp backend: without it SLIRP hands the guest a default
# route via 10.0.2.2 and the guest can reach whatever the host's stack can. The
# station needs nothing outbound on this NIC — it is the pointer path only — so
# the backend is restricted and `hostfwd` (host -> guest) keeps working. This is
# a BACKEND option, not a device change, but the golden is baked with the exact
# launcher regardless.
#
# X pointer forward: host loopback 6078 -> guest 10.0.2.15:6000. SLIRP forwards
# are host-side state, not vmstate, so declaring it on -netdev re-adds it every
# start without touching the device set. The guest's only interfaces are ne2
# (SLIRP) and lo0; the golden carries `xhost +10.0.2.2` (never `xhost +`).
X_PORT=6078
# shellcheck disable=SC2086 # $LOADVM is "-loadvm golden -S" or empty: word-splitting is the point
nohup "${FREEBSD411_QEMU:-/opt/qemu-beos/bin/qemu-system-x86_64}" \
  -name streamhost-freebsd411 \
  -enable-kvm -m 256 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off -cpu host \
  -rtc base=localtime \
  -boot c \
  $LOADVM \
  -vga std \
  -display dbus,p2p=on \
  -device lsi53c895a,id=scsi0 \
  -drive file=/data/vms/streamhost/stations/freebsd411/disk.qcow2,format=qcow2,if=none,id=hd0 \
  -device scsi-hd,bus=scsi0.0,drive=hd0 \
  -netdev user,id=n0,restrict=on,hostfwd=tcp:127.0.0.1:${X_PORT}-10.0.2.15:6000 -device ne2k_pci,netdev=n0 \
  -netdev tap,id=rn0,ifname=freebsd411rn0,script=no,downscript=no -device e1000,netdev=rn0,mac="$RN_MAC" \
  -qmp unix:/data/vms/streamhost/stations/freebsd411/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/stations/freebsd411/qemu.pid \
  >"/data/vms/streamhost/stations/freebsd411/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
# X access CHECK (not configuration — there is no exec channel): a bare X11
# connection-setup handshake over the forward; first reply byte 1 = accepted.
# Logs `x11warp ok` or `x11warp STALE GOLDEN` (-> checkpoint-guard recapture).
cat >"$BASE/x11warp-check.sh" <<'CHECK'
#!/bin/sh
X_PORT="$1"; n=0
while [ "$n" -lt 600 ]; do
  python3 -c '
import socket, struct, sys
try:
    s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 3)
    s.sendall(struct.pack(">ccHHHHH", b"B", b"\0", 11, 0, 0, 0, 0))
    sys.exit(0 if s.recv(8)[:1] == b"\1" else 1)
except Exception:
    sys.exit(2)
' "$X_PORT"
  rc=$?
  [ "$rc" -eq 0 ] && { echo "$(date -u +%FT%TZ) x11warp ok: the golden carries the X access state"; exit 0; }
  [ "$rc" -eq 1 ] && { echo "$(date -u +%FT%TZ) x11warp STALE GOLDEN: the X server refused the SLIRP peer -- ssh lab 'checkpoint-guard recapture freebsd411'"; exit 1; }
  n=$((n + 1)); sleep 1
done
echo "$(date -u +%FT%TZ) x11warp TIMED OUT: the guest X server never answered on ${X_PORT}"; exit 1
CHECK
chmod +x "$BASE/x11warp-check.sh"
setsid nohup "$BASE/x11warp-check.sh" "$X_PORT" >>"$BASE/x11warp-bootstrap.log" 2>&1 &
echo "station freebsd411 qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54178 x11=127.0.0.1:${X_PORT} loadvm='${LOADVM:-<none: cold boot>}'"
