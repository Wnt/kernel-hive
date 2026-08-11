#!/bin/bash
# (Re)bake the 'golden' snapshot for tile tinycore from a COLD LiveCD boot.
# Use after a bare-metal/NVMe rebuild that wiped state.qcow2. Unlike a text-console
# tile, tinycore's fixture needs the MOUSE (to open the aterm terminal from the wbar
# dock), and tinyX is relative-only, so this bakes under the VNC setup launcher where
# both QMP keyboard and the legacy relative-mouse path are reliable. The resulting
# snapshot is portable to the production dbus launcher (verified: loadvm golden gives
# a byte-identical framebuffer under both).
set -e
BASE=/data/vms/streamhost/tiles/tinycore
STATE="$BASE/state.qcow2"
DRIVE="python3 $BASE/drive.py $BASE/qmp.sock"

echo "[bake] fresh state.qcow2 (vmstate container) + empty-base backup"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 1
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid" "$STATE"
qemu-img create -q -f qcow2 "$STATE" 3G
cp -a "$STATE" "$STATE.base-empty" # backup empty base before any savevm (rule)

echo "[bake] boot LiveCD under the VNC setup launcher"
bash "$BASE/qemu-setup-vnc.sh"
sleep 3

echo "[bake] dismiss ISOLINUX menu -> boot TinyCore GUI, wait for desktop"
$DRIVE key ret sleep 30

echo "[bake] open aterm from wbar dock (legacy relative mouse) + focus it"
$DRIVE click 613 740 sleep 3 # rightmost dock icon = Terminal
$DRIVE click 250 150 sleep 1 # click inside -> focus (focus-follows-mouse)

echo "[bake] tweaks: screensaver/blank/DPMS off, clean prompt; park pointer in terminal"
$DRIVE type 'xset s off; xset s noblank; xset -dpms; clear' key ret sleep 1
$DRIVE mouse 250 150 sleep 1

echo "[bake] determinism check (two idle screendumps must be byte-identical)"
$DRIVE shot "$BASE/g1.ppm" sleep 1.6 shot "$BASE/g2.ppm"
cmp "$BASE/g1.ppm" "$BASE/g2.ppm" && echo "  OK: zero idle animation" || {
  echo "  FAIL: idle animation"
  exit 1
}

echo "[bake] savevm golden"
$DRIVE delvm golden >/dev/null 2>&1 || true
$DRIVE savevm golden sleep 1 querysnap

echo "[bake] verify loadvm golden (dirty -> loadvm -> compare)"
$DRIVE type 'echo DIRTY' key ret sleep 1 shot "$BASE/gd.ppm"
$DRIVE loadvm golden sleep 1 shot "$BASE/gr.ppm"
cmp "$BASE/g1.ppm" "$BASE/gr.ppm" && echo "  OK: loadvm golden == fixture" || {
  echo "  FAIL: loadvm mismatch"
  exit 1
}

echo "[bake] kill setup QEMU (by pidfile); back up golden disk for the NVMe rebuild"
kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 1
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
cp -a "$STATE" "$STATE.bak-$(date +%Y%m%d)"
qemu-img snapshot -l "$STATE"
echo "[bake] done. Production launch auto -loadvm golden:  bash $BASE/qemu-streamhost.sh"
