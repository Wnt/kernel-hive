#!/bin/bash
# Reproduce the postmarketos GOLDEN TEST FIXTURE guest bake on a fresh NVMe rebuild.
#
# What it does (idempotent, offline via qemu-nbd):
#   0. (optional) convert the pristine raw base -> qcow2, and OVMF_VARS.fd -> qcow2
#   1. set the 'user' login PIN to 147147
#   2. install /usr/local/bin/golden-fixture.sh (no-blank/no-lock/steady-caret/OSK-off + open GNOME Console)
#   3. add the user autostart entry that runs it every phosh login
#   4. disable the first-login Phosh Tour
#
# After running this, boot the tile WITHOUT the 'golden' snapshot once, unlock with
# PIN 147147, let the fixture settle, then QMP `savevm golden`. qemu-streamhost.sh
# will auto-resume it (-loadvm golden) on every subsequent launch. resetMode=loadvm.
set -euo pipefail
D=/data/gallery-guests/postmarketOS
T=/data/vms/streamhost/tiles/postmarketos
RAW=$D/pmos-phosh.img
QCOW=$D/pmos-phosh.qcow2
VARS_FD=$T/OVMF_VARS.fd.pristine
VARS_QCOW=$T/OVMF_VARS.qcow2
NBD=${NBD:-/dev/nbd0}

modprobe nbd max_part=8 2>/dev/null || true

if [ ! -f "$QCOW" ]; then
  echo "[*] converting raw base -> qcow2"
  qemu-img convert -p -O qcow2 -o compat=1.1 "$RAW" "$QCOW"
fi
if [ ! -f "$VARS_QCOW" ]; then
  echo "[*] converting OVMF_VARS -> qcow2"
  qemu-img convert -O qcow2 -f raw "$VARS_FD" "$VARS_QCOW"
fi

echo "[*] attaching $QCOW on $NBD"
qemu-nbd --disconnect "$NBD" 2>/dev/null || true
qemu-nbd --connect="$NBD" -f qcow2 "$QCOW"
sleep 1
partprobe "$NBD" 2>/dev/null || true
sleep 1
mkdir -p /mnt/pmrw
mount "${NBD}p2" /mnt/pmrw
R=/mnt/pmrw
cleanup() {
  sync
  umount /mnt/pmrw 2>/dev/null || true
  qemu-nbd --disconnect "$NBD" 2>/dev/null || true
}
trap cleanup EXIT

echo "[*] set user PIN 147147"
HASH=$(openssl passwd -6 147147)
python3 - "$R/etc/shadow" "$HASH" <<'PY'
import sys
path,h=sys.argv[1],sys.argv[2]
out=[]
for l in open(path).read().splitlines():
    f=l.split(':')
    if f[0]=='user': f[1]=h; l=':'.join(f)
    out.append(l)
open(path,'w').write('\n'.join(out)+'\n')
PY

echo "[*] install golden-fixture.sh"
install -d -m755 "$R/usr/local/bin"
install -m755 "$(dirname "$0")/golden-fixture.sh" "$R/usr/local/bin/golden-fixture.sh"

echo "[*] user autostart + tour disable"
install -d -m700 "$R/home/user/.config/autostart"
cat >"$R/home/user/.config/autostart/zz-golden-fixture.desktop" <<'DA'
[Desktop Entry]
Type=Application
Name=Golden Fixture Setup
Exec=/usr/local/bin/golden-fixture.sh
X-GNOME-Autostart-enabled=true
OnlyShowIn=Phosh;GNOME;
NoDisplay=true
DA
cat >"$R/home/user/.config/autostart/mobi.phosh.PhoshTour-first-login.desktop" <<'DT'
[Desktop Entry]
Type=Application
Name=Phone Tour
Exec=phosh-tour --run-once
Hidden=true
X-GNOME-Autostart-enabled=false
DT
install -d -m700 "$R/home/user/.config/systemd/user"
ln -sf /dev/null "$R/home/user/.config/systemd/user/mobi.phosh.PhoshTour-first-login.service"
chown -R 10000:10000 "$R/home/user/.config"

echo "[*] done. Now boot fresh, unlock 147147, settle, then QMP: savevm golden"
