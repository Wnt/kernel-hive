#!/bin/bash
# Bake the vendored Solaris warpd agent into the existing clean CDE golden.
# This is intentionally end to end: it launches the pinned tile shape, injects
# the files/config, replaces the golden snapshot, resets to it, and proves exec.
set -euo pipefail

REPO="${REPO:-/data/vms/streamhost/build}"
SRC="$REPO/streamhost/guest-agents/solaris"
TILE=/data/vms/streamhost/stations/solaris
DISK="$TILE/solariscde-golden.qcow2"
QMP="$TILE/qmp.sock"
CDRIVE=(python3 /root/cdrv.py "$QMP")
SNAPDRIVE=(python3 "$TILE/drive.py" "$QMP")
HTTP_PORT="${HTTP_PORT:-8099}"
HPID=""

cleanup() {
  if [ -n "$HPID" ] && kill -0 "$HPID" 2>/dev/null; then
    kill "$HPID" 2>/dev/null || true
    wait "$HPID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

G() {
  "${CDRIVE[@]}" sh "$1"
  sleep "${2:-1.5}"
}

probe() {
  local i
  for i in $(seq 1 20); do
    if timeout 15 /root/gexec.py 57790 "$@"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

for f in warpd.py gexec.py cdrv.py; do
  test -s "$SRC/$f" || {
    echo "missing vendored source: $SRC/$f" >&2
    exit 1
  }
done
test -s "$DISK"
qemu-img snapshot -l "$DISK" | awk 'NR > 2 {print $2}' | grep -qx golden || {
  echo "clean golden snapshot is missing from $DISK" >&2
  exit 1
}

echo "[warpd-bake] stage the vendored host tools and stop the live tile"
install -m 0755 "$SRC/cdrv.py" /root/cdrv.py
install -m 0755 "$SRC/gexec.py" /root/gexec.py
systemctl stop streamhost@solaris 2>/dev/null || true
if [ -s "$TILE/qemu.pid" ]; then
  pid=$(cat "$TILE/qemu.pid")
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
fi
rm -f "$QMP" "$TILE/qemu.pid"

backup="$DISK.pre-warpd-$(date -u +%Y%m%dT%H%M%SZ)"
echo "[warpd-bake] preserve pre-bake disk as $backup"
cp --reflink=auto "$DISK" "$backup"

echo "[warpd-bake] launch the pinned pc-i440fx-11.0 tile at nice 15; launcher loads clean golden"
nice -n15 bash "$REPO/streamhost/stations/solaris/qemu-streamhost.sh"
sleep 3

echo "[warpd-bake] serve the vendored agent to the guest over SLIRP"
(
  cd "$SRC"
  exec python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0
) >/tmp/solaris-warpd-http.log 2>&1 &
HPID=$!
sleep 2
kill -0 "$HPID"

G 'ifconfig e1000g1 plumb 2>/dev/null || true; ifconfig e1000g1 10.0.2.15 netmask 255.255.255.0 up' 2
G 'mkdir -p /opt/warpd' 1
G "python -c 'import urllib; open(\"/opt/warpd/warpd.py\",\"w\").write(urllib.urlopen(\"http://10.0.2.2:$HTTP_PORT/warpd.py\").read())'" 4
G 'chmod 755 /opt/warpd/warpd.py' 1
cleanup
HPID=""

echo "[warpd-bake] install cold-boot network and CDE-session autostart"
G 'echo "10.0.2.15 netmask 255.255.255.0 up" > /etc/hostname.e1000g1' 1
G 'mkdir -p /etc/dt/config/Xsession.d' 1
G 'echo "DISPLAY=:0 /usr/bin/python /opt/warpd/warpd.py 7777 >/var/tmp/warpd.log 2>&1 &" > /etc/dt/config/Xsession.d/0100.warpd.sh' 1
G 'chmod 755 /etc/dt/config/Xsession.d/0100.warpd.sh' 1
G 'pkill -f "/opt/warpd/warpd.py 7777" 2>/dev/null || true; DISPLAY=:0 /usr/bin/python /opt/warpd/warpd.py 7777 >/var/tmp/warpd.log 2>&1 &' 3

# Opaque moves prevent dtwm's server grab from wedging synthetic drag release.
G 'mkdir -p /etc/dt/config/C; grep -q moveOpaque /etc/dt/config/C/sys.resources 2>/dev/null || echo "Dtwm*moveOpaque: True" >> /etc/dt/config/C/sys.resources' 1
G 'echo "Dtwm*moveOpaque: True" > /tmp/mvd.ad; DISPLAY=:0 /usr/openwin/bin/xrdb -merge /tmp/mvd.ad' 1
G 'pkill -9 -x dtwm; sleep 2; DISPLAY=:0 /usr/dt/bin/dtwm >/tmp/wm.log 2>&1 &' 3
G 'sync' 1
"${SNAPDRIVE[@]}" click 500 400 sleep 1
G 'clear' 2
# CDE uses an 8-bit focus-sensitive colormap.  Leave keyboard focus in the
# terminal, but park the pointer on the root window so screendump/savevm retain
# the desktop palette instead of rendering non-terminal regions black.
python3 -c 'import socket; s=socket.create_connection(("127.0.0.1", 57790), 5); s.sendall(b"M 1350 650\n"); s.close()'
sleep 2

expected=$(sha256sum "$SRC/warpd.py" | awk '{print $1}')
actual=$(probe "python -c 'import hashlib; print hashlib.sha256(open(\"/opt/warpd/warpd.py\",\"rb\").read()).hexdigest()'")
test "$actual" = "$expected" || {
  echo "agent hash mismatch: expected $expected, guest has $actual" >&2
  exit 1
}
echo "[warpd-bake] guest agent sha256 verified: $actual"
probe "test -x /etc/dt/config/Xsession.d/0100.warpd.sh -a -f /etc/hostname.e1000g1"

echo "[warpd-bake] replace snapshot golden with the running, persistent agent"
probe sync
"${SNAPDRIVE[@]}" delvm golden >/dev/null 2>&1 || true
"${SNAPDRIVE[@]}" savevm golden sleep 2 querysnap

echo "[warpd-bake] restart service, reset through labctl, then prove the restored exec channel"
systemctl restart streamhost@solaris
sleep 3
renice 15 -p "$(cat "$TILE/qemu.pid")" >/dev/null
labctl reset solaris
sleep 3
timeout 30 labctl exec solaris "uname -a"
labctl shot solaris /tmp/solaris-warpd-golden.png >/dev/null
systemctl is-active streamhost@solaris
echo "[warpd-bake] PASS: golden reset is agent-reachable; framebuffer /tmp/solaris-warpd-golden.png"
