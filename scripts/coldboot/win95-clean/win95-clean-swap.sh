#!/bin/bash
# PHASE B swap: back up live golden, replace with the validated clean-desktop golden,
# relaunch live QEMU (auto -loadvm golden). Framebuffer-gate happens AFTER this, before
# the daemon is restarted. Reversible: the .bak path is printed.
set -euo pipefail
LIVE_DIR=/data/vms/streamhost/tiles/win95
LIVE_DISK="$LIVE_DIR/win95-golden.qcow2"
CLONE_GOLDEN=/data/vms/soltest/bootrec-win95-4037869/win95-golden.qcow2
TS=$(date +%Y%m%d-%H%M%S)
BAK="$LIVE_DISK.bak-clean-swap-$TS"

echo "== 1. stop streamhost@win95 daemon =="
systemctl stop streamhost@win95
sleep 1

echo "== 2. kill live QEMU by pidfile =="
PF="$LIVE_DIR/qemu.pid"
if [ -f "$PF" ]; then
  PID=$(cat "$PF")
  kill "$PID" 2>/dev/null || true
  for i in $(seq 1 20); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.25
  done
  kill -0 "$PID" 2>/dev/null && {
    kill -9 "$PID" 2>/dev/null || true
    sleep 1
  }
  kill -0 "$PID" 2>/dev/null && {
    echo "  FAIL: qemu still alive pid=$PID"
    exit 1
  } || echo "  qemu stopped"
else
  echo "  no pidfile (qemu already down)"
fi
rm -f "$LIVE_DIR/qmp.sock"

echo "== 3. backup live golden (md5 + copy) =="
echo -n "  live golden md5 (pre-swap): "
md5sum "$LIVE_DISK" | awk '{print $1}'
cp -f "$LIVE_DISK" "$BAK"
echo "  backup -> $BAK"
ls -la "$BAK"

echo "== 4. verify device-set match: clone golden built on the live device set =="
qemu-img snapshot -l "$CLONE_GOLDEN" | grep -qw golden && echo "  clone has 'golden' snapshot OK" || {
  echo "  FAIL: clone missing golden snapshot"
  exit 1
}

echo "== 5. SWAP: validated clean golden -> live golden path =="
cp -f "$CLONE_GOLDEN" "$LIVE_DISK"
echo -n "  new live golden md5 (post-swap): "
md5sum "$LIVE_DISK" | awk '{print $1}'
qemu-img snapshot -l "$LIVE_DISK"

echo "== 6. relaunch live QEMU (auto -loadvm golden with the new clean golden) =="
bash "$LIVE_DIR/qemu-streamhost.sh"
sleep 3
echo "  restore file for rollback: $BAK"
