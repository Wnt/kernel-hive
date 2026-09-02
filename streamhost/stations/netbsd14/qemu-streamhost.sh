#!/bin/bash
# netbsd14 — NetBSD 1.4.1 i386 (1999), XFree86 3.3.3.1 SVGA on the emulated Cirrus.
# Scaffolded from pcgeos (same pc-i440fx-11.0 KVM device set) on 2026-09-02;
# the pointer route is sunos414's: pointer MOTION is absolute through the guest's
# own X server (SH_INPUT_BACKEND=x11warp on SH_X11WARP_DISPLAY=127.0.0.1:76 via
# the loopback SLIRP forward below), buttons + keys ride the D-Bus PS/2 path.
#
# disk.qcow2 is the ONLY block device and carries the 'golden' vmstate. Baked
# under /opt/qemu-beos (QEMU 11.0.2 fork, same machine types as the host pve
# build): golden + binary + device set are ONE combination (rule 6).
set -e
BASE=/data/vms/streamhost/stations/netbsd14
DISK="$BASE/disk.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
[ -f "$DISK" ] || cp /data/gallery-guests/NETBSD14/netbsd14.qcow2 "$DISK"
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# X pointer forward: host loopback 6076 -> guest 10.0.2.15:6000. SLIRP forwards
# are host-side state, not vmstate, so declaring it on -netdev re-adds it every
# start without touching the device set. The guest's only interfaces are ne2
# (SLIRP) and lo0; the golden carries `xhost +10.0.2.2` (never `xhost +`).
X_PORT=6076
nohup "${NETBSD14_QEMU:-/opt/qemu-beos/bin/qemu-system-x86_64}" \
  -name streamhost-netbsd14 \
  -enable-kvm -m 128 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off -cpu host \
  -rtc base=localtime \
  -boot c \
  $LOADVM \
  -vga cirrus \
  -display dbus,p2p=on \
  -drive file=/data/vms/streamhost/stations/netbsd14/disk.qcow2,format=qcow2,if=ide \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${X_PORT}-10.0.2.15:6000 -device ne2k_pci,netdev=n0 \
  -qmp unix:/data/vms/streamhost/stations/netbsd14/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/stations/netbsd14/qemu.pid \
  >"/data/vms/streamhost/stations/netbsd14/qemu.log" 2>&1 &
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
  [ "$rc" -eq 1 ] && { echo "$(date -u +%FT%TZ) x11warp STALE GOLDEN: the X server refused the SLIRP peer -- ssh lab 'checkpoint-guard recapture netbsd14'"; exit 1; }
  n=$((n + 1)); sleep 1
done
echo "$(date -u +%FT%TZ) x11warp TIMED OUT: the guest X server never answered on ${X_PORT}"; exit 1
CHECK
chmod +x "$BASE/x11warp-check.sh"
setsid nohup "$BASE/x11warp-check.sh" "$X_PORT" >>"$BASE/x11warp-bootstrap.log" 2>&1 &
echo "station netbsd14 qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54176 x11=127.0.0.1:${X_PORT} loadvm='${LOADVM:-<none: cold boot>}'"
