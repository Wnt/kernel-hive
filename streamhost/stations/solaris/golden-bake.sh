#!/bin/bash
# ============================================================================
# (Re)bake the 'golden' snapshot for tile solaris from the PRISTINE Oracle
# Solaris 10 x86 CDE gallery image. Use after a bare-metal/NVMe rebuild that
# wiped solariscde-golden.qcow2.
#
# FAST PATH (preferred): ship solariscde-golden.qcow2.bak-20260707 as
#   solariscde-golden.qcow2 and just run qemu-streamhost.sh (auto -loadvm golden).
# This script is the SLOW PATH: it rebuilds the snapshot from the PRISTINE shared
#   gallery image /data/gallery-guests/SolarisCDE/solaris.qcow2 (left untouched).
#
# resetMode=loadvm. The guest tweaks live in TWO baked config files (dropped here
# from a single-user root shell, since Linux cannot safely write Solaris UFS):
#   * /usr/dt/config/Xsession.d/9999.golden-fixture  (per-login: xset screensaver/
#     DPMS off, kill sdtperfmeter + first-login clutter, launch a focused
#     non-blinking dtterm reactive surface). Repo copy: $BASE/9999.golden-fixture
#   * /etc/dt/appconfig/types/C/golden-fixture.fp     (remove the animated
#     front-panel analog Clock control). Repo copy: $BASE/golden-fixture.fp
#   (The base image is already delocked -- dtsession saver/lock/cycle timeouts 0.)
#
# The GUI is UNDRIVABLE by synthetic QMP mouse (CDE Motif menus need real
# press-drag motion + the usb-tablet pointer freezes during a button grab), so
# the whole bake is done over the KEYBOARD (GRUB -> single-user -> config drop;
# reboot -> dtlogin type root/solaris; the Xsession.d hook builds the desktop with
# NO menu driving). drive.py provides QMP keyboard/screendump/snapshot. Login
# root/solaris (also the single-user maintenance password). Kill only by pidfile.
# ============================================================================
set -e
BASE=/data/vms/streamhost/stations/solaris
DISK="$BASE/solariscde-golden.qcow2"
SRC=/data/gallery-guests/SolarisCDE/solaris.qcow2
DRIVE="python3 $BASE/drive.py $BASE/qmp.sock"

echo "[bake] stop streamhost + any running solaris qemu (by pidfile); fresh golden disk from PRISTINE source"
systemctl stop streamhost@solaris 2>/dev/null || true
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 2
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
cp "$SRC" "$DISK"
cp "$DISK" "$DISK.pre-savevm" # backup before any savevm (rule)

echo "[bake] boot the golden disk (NO -snapshot) -- cold, no snapshot yet"
bash "$BASE/qemu-streamhost.sh" # auto-detects no snapshot => cold boot to GRUB

echo "[bake] drive GRUB -> single-user (edit the multiboot line: append ' -s')"
$DRIVE raw system_reset sleep 3 key up up up up up up up up up up up up sleep 0.5 # halt the countdown
$DRIVE key e sleep 1.2 key down sleep 0.4 key e sleep 0.8 type " -s" sleep 0.4 key ret sleep 0.6 key b
echo "[bake] wait for the single-user root password prompt (~55s), authenticate root/solaris"
sleep 60
$DRIVE type solaris key ret sleep 5

echo "[bake] drop the two baked config files from the maintenance shell"
$DRIVE type "cat > /usr/dt/config/Xsession.d/9999.golden-fixture" key ret sleep 0.5
$DRIVE typefile "$BASE/9999.golden-fixture" sleep 0.5
$DRIVE kc c d sleep 1
$DRIVE type "chmod 755 /usr/dt/config/Xsession.d/9999.golden-fixture" key ret sleep 1
$DRIVE type "mkdir -p /etc/dt/appconfig/types/C" key ret sleep 1
$DRIVE type "cat > /etc/dt/appconfig/types/C/golden-fixture.fp" key ret sleep 0.5
$DRIVE typefile "$BASE/golden-fixture.fp" sleep 0.5
$DRIVE kc c d sleep 1
$DRIVE type "sync; sync" key ret sleep 2

echo "[bake] reboot to multi-user CDE (init 6), wait for dtlogin greeter (~120s)"
$DRIVE type "init 6" key ret
sleep 125

echo "[bake] log in root/solaris at dtlogin (Start Over guards stray input first)"
$DRIVE click 1104 747 sleep 2 click 960 651 sleep 0.5 type root key ret sleep 3 type solaris key ret

echo "[bake] wait for CDE + the Xsession.d hook (sleep 14 in-hook) to build the fixture (~35s)"
sleep 35

echo "[bake] into the auto-opened dtterm: clear the utmp:default maintenance if present, fresh prompt, park pointer"
# (utmp:default can land in maintenance if a boot race leaves a stale utmpd; harmless to run when healthy.)
$DRIVE click 500 400 sleep 0.5 type "pkill -x utmpd; sleep 1; svcadm clear system/utmp 2>/dev/null; clear" key ret sleep 4
$DRIVE mouse 1350 650 sleep 1

echo "[bake] determinism check: 4 idle screendumps must be byte-identical"
$DRIVE shot "$BASE/g0.ppm" sleep 3 shot "$BASE/g1.ppm" sleep 3 shot "$BASE/g2.ppm" sleep 3 shot "$BASE/g3.ppm"
for f in g1 g2 g3; do cmp "$BASE/g0.ppm" "$BASE/$f.ppm" || {
  echo "  FAIL: idle animation ($f) -- inspect $BASE/g*.ppm"
  exit 1
}; done
echo "  OK: zero idle animation over ~9s"
cp "$BASE/g0.ppm" "$BASE/GOLDEN.ppm"

echo "[bake] savevm golden"
$DRIVE delvm golden >/dev/null 2>&1 || true
$DRIVE savevm golden sleep 1 querysnap

echo "[bake] verify reactive + loadvm (type -> differs -> loadvm -> byte-identical)"
$DRIVE type "echo HELLO GOLDEN FIXTURE -- keyboard reactive" sleep 0.6 shot "$BASE/typed.ppm"
cmp -s "$BASE/GOLDEN.ppm" "$BASE/typed.ppm" && {
  echo "  FAIL: keyboard not reactive"
  exit 1
} || echo "  OK: keyboard reactive"
$DRIVE loadvm golden sleep 1.2 shot "$BASE/restored.ppm"
cmp "$BASE/GOLDEN.ppm" "$BASE/restored.ppm" && echo "  OK: loadvm golden == fixture (byte-identical)" || {
  echo "  FAIL: loadvm mismatch"
  exit 1
}

echo "[bake] consistent golden-disk backup for the NVMe rebuild (pause -> reflink copy -> resume)"
$DRIVE raw stop
cp "$DISK" "$DISK.bak-$(date +%Y%m%d)"
$DRIVE raw cont
qemu-img snapshot -l "$DISK"

echo "[bake] restart the tile's streamhost daemon (serves udp/54100 at the fixture)"
systemctl start streamhost@solaris
sleep 3
systemctl is-active streamhost@solaris
echo "[bake] done. Production launch auto -loadvm golden:  bash $BASE/qemu-streamhost.sh"
