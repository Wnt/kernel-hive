#!/bin/bash
# (Re)bake the 'golden' snapshot for tile winxp from a COLD Windows XP boot.
# Use after a bare-metal/NVMe rebuild that wiped winxp-golden.qcow2. Rebuilds
# from the PRISTINE shared gallery image (autologon + VBEMP 1920x1200 baked).
#
# WinXP fixture baked here (see GOLDEN.md / tile.env.fixture):
#   * Administrator autologon (already in the pristine SOFTWARE hive).
#   * Notepad open+focused (empty doc, caret top-left), pointer parked right.
#   * Screensaver OFF; power scheme "Always On", all timeouts 0 (powercfg).
#   * Tray clock HIDDEN (policy HideClock=1).
#   * Caret blink quieted (HKCU CursorBlinkRate=2000000000) so the Notepad caret
#     does not toggle within the acceptance window.
#   * Security Center + Automatic Updates services disabled (no idle balloons).
#   * Full-window drag OFF (baked by winxp-vbemp-hires.sh; reasserted here).
# All tweaks that survive a reboot are injected OFFLINE (hivexregedit into the
# NTFS SOFTWARE/SYSTEM/NTUSER.DAT hives); the live-only bits (Notepad, powercfg,
# pointer park) are driven over QMP with screendump feedback. Kill only by pidfile.
set -e
BASE=/data/vms/streamhost/tiles/winxp
DISK="$BASE/winxp-golden.qcow2"
SRC=/data/gallery-guests/WinXPpro/winxp.qcow2
DRIVE="python3 $BASE/drive.py $BASE/qmp.sock"
MNT=/mnt/winxpg
# pick a free nbd node (concurrent-agent-safe)
pick_nbd() {
  modprobe nbd max_part=8 2>/dev/null || true
  local n
  for n in 4 5 6 7 8 9 10 11; do
    if [ "$(cat /sys/block/nbd$n/size 2>/dev/null || echo 0)" = "0" ]; then
      echo "/dev/nbd$n"
      return 0
    fi
  done
  return 1
}

grep -Eq -- '-machine pc-i440fx-[0-9]+\.[0-9]+ ' "$BASE/qemu-streamhost.sh" || {
  echo "[bake] FAIL: launcher machine type is not pinned" >&2
  exit 1
}
[ -f "$SRC" ] || {
  echo "[bake] FAIL: pristine source missing: $SRC" >&2
  exit 1
}

echo "[bake] stop service + winxp qemu (by pidfile), fresh golden disk from pristine"
systemctl stop streamhost@winxp 2>/dev/null || true
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 2
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
if [ -f "$DISK" ]; then cp --reflink=auto "$DISK" "$DISK.before-bake-$(date +%Y%m%d-%H%M%S)"; fi
cp "$SRC" "$DISK"
cp --reflink=auto "$DISK" "$DISK.pre-savevm" # backup before any savevm (rule)

echo "[bake] OFFLINE: fixture registry tweaks into SOFTWARE / SYSTEM / NTUSER.DAT"
NBD="$(pick_nbd)" || {
  echo "[bake] FAIL: no free nbd node"
  exit 1
}
echo "  using $NBD"
qemu-nbd -c "$NBD" "$DISK"
sleep 2
partprobe "$NBD" 2>/dev/null || true
mkdir -p "$MNT"
mount -t ntfs-3g "${NBD}p1" "$MNT"
SOFT="$MNT/WINDOWS/system32/config/software"
SYS="$MNT/WINDOWS/system32/config/system"
NTU="$MNT/Documents and Settings/Administrator/NTUSER.DAT"
[ -f "$SOFT" ] && [ -f "$SYS" ] && [ -f "$NTU" ] || {
  echo "[bake] FAIL: hive(s) not found"
  # shellcheck disable=SC2012 # diagnostic listing of our own mount, not adversarial input
  ls -la "$MNT/WINDOWS/system32/config" | head
  umount "$MNT"
  qemu-nbd -d "$NBD"
  exit 1
}

# SOFTWARE: permanent autologon (reassert) + Security Center notify-off
cat >/tmp/xp-soft.reg <<'REG'
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon]
"AutoAdminLogon"="1"
"DefaultUserName"="Administrator"
"DefaultDomainName"="RETROXP"
"DefaultPassword"="retro"
"ForceAutoLogon"="1"
"AutoLogonCount"=-
"LogonType"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Security Center]
"AntiVirusDisableNotify"=dword:00000001
"FirewallDisableNotify"=dword:00000001
"UpdatesDisableNotify"=dword:00000001
"AntiVirusOverride"=dword:00000001
"FirewallOverride"=dword:00000001
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SOFTWARE' "$SOFT" /tmp/xp-soft.reg
echo "  SOFTWARE: autologon + Security Center notify-off merged"

# SYSTEM: disable Security Center (wscsvc) + Automatic Updates (wuauserv) services
cat >/tmp/xp-sys.reg <<'REG'
[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\wscsvc]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\wuauserv]
"Start"=dword:00000004
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$SYS" /tmp/xp-sys.reg
echo "  SYSTEM: wscsvc + wuauserv disabled"

# NTUSER.DAT (Administrator HKCU): caret quiet, screensaver off, drag off, hide clock, Always On active
cat >/tmp/xp-user.reg <<'REG'
[HKEY_CURRENT_USER\Control Panel\Desktop]
"CursorBlinkRate"="2000000000"
"ScreenSaveActive"="0"
"ScreenSaveTimeOut"="0"
"DragFullWindows"="0"

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer]
"HideClock"=dword:00000001

[HKEY_CURRENT_USER\Control Panel\PowerCfg]
"CurrentPowerPolicy"="5"
REG
hivexregedit --merge --prefix 'HKEY_CURRENT_USER' "$NTU" /tmp/xp-user.reg
echo "  NTUSER.DAT: caret quiet + screensaver/drag off + clock hidden + Always On"

rm -f "$MNT/WINDOWS/bootstat.dat" 2>/dev/null || true
sync
umount "$MNT"
qemu-nbd -d "$NBD" >/dev/null 2>&1
sleep 1
rm -f /tmp/xp-soft.reg /tmp/xp-sys.reg /tmp/xp-user.reg

echo "[bake] BOOT 1 (cold; no snapshot yet) via production launcher; let AC97 auto-install + settle"
bash "$BASE/qemu-streamhost.sh"
$DRIVE sleep 95 shot "$BASE/bake_boot1.ppm"
echo "[bake] REBOOT so the AC97 'Found New Hardware' event clears (the fixture must be balloon-free)"
$DRIVE kc c esc sleep 1.5 key r sleep 1.5 type 'shutdown -r -t 00 -f' key ret sleep 2
echo "[bake] BOOT 2 (AC97 already installed on the production PCI slot -> clean), wait for autologon"
$DRIVE sleep 80 shot "$BASE/bake_desktop.ppm"

echo "[bake] in-guest: powercfg Always On + all timeouts 0 (belt-and-suspenders; no '&')"
$DRIVE kc c esc sleep 1.5 key r sleep 1.5 \
  type 'cmd /c powercfg /change "Always On" /monitor-timeout-ac 0 /disk-timeout-ac 0 /standby-timeout-ac 0 /hibernate-timeout-ac 0' \
  key ret sleep 2.5
$DRIVE kc c esc sleep 1.5 key r sleep 1.5 type 'cmd /c powercfg /setactive "Always On"' key ret sleep 2.5

echo "[bake] open Notepad (empty), focus edit area, park caret top-left"
$DRIVE kc c esc sleep 1.5 key r sleep 1.5 type 'notepad' key ret sleep 3
$DRIVE key home
echo "[bake] park pointer to the right, out of the surface"
$DRIVE mouse 1850 620 sleep 1
echo "[bake] settle ~25s so any first-run balloons expire before determinism"
$DRIVE sleep 25 shot "$BASE/bake_notepad.ppm"

frame_equal_or_caret() {
  python3 - "$1" "$2" <<'PY'
import sys
def ppm(path):
    raw=open(path,'rb').read()
    magic,w,h,maxv,pixels=raw.split(None,4)
    assert magic==b'P6' and maxv==b'255'
    return int(w),int(h),pixels
w,h,a=ppm(sys.argv[1]); w2,h2,b=ppm(sys.argv[2])
assert (w,h)==(w2,h2), 'size mismatch'
pts=[i for i in range(w*h) if a[i*3:i*3+3] != b[i*3:i*3+3]]
if not pts:
    print('identical'); raise SystemExit(0)
xs=[p%w for p in pts]; ys=[p//w for p in pts]
x0,y0,x1,y1=min(xs),min(ys),max(xs),max(ys)
if len(pts)<=80 and x1-x0+1<=3 and y1-y0+1<=24:
    print('caret-only: changed=%d bbox=(%d,%d)-(%d,%d)'%(len(pts),x0,y0,x1,y1)); raise SystemExit(0)
print('unexpected motion: changed=%d bbox=(%d,%d)-(%d,%d)'%(len(pts),x0,y0,x1,y1)); raise SystemExit(1)
PY
}

echo "[bake] determinism: two no-input frames 3s apart must be byte-identical"
$DRIVE shot "$BASE/det0.ppm" sleep 3 shot "$BASE/det1.ppm"
if cmp -s "$BASE/det0.ppm" "$BASE/det1.ppm"; then
  echo "  PASS: byte-identical (3s apart)"
else
  echo "  NOTE: not byte-identical; checking caret-only tolerance"
  frame_equal_or_caret "$BASE/det0.ppm" "$BASE/det1.ppm" || {
    echo "  FAIL: idle animation beyond caret"
    exit 1
  }
  echo "  (caret-only delta; re-sampling for a clean byte-identical pair)"
  $DRIVE sleep 2 shot "$BASE/det2.ppm" sleep 3 shot "$BASE/det3.ppm"
  cmp -s "$BASE/det2.ppm" "$BASE/det3.ppm" && echo "  PASS: byte-identical on re-sample" || {
    echo "  FAIL: still not byte-identical"
    exit 1
  }
fi

echo "[bake] savevm golden"
$DRIVE delvm golden >/dev/null 2>&1 || true
$DRIVE shot "$BASE/GOLDEN.ppm" savevm golden sleep 1 querysnap

echo "[bake] verify reactive + loadvm (type -> differs -> loadvm -> matches fixture)"
$DRIVE type 'HELLO WINXP GOLDEN' sleep 0.5 shot "$BASE/typed.ppm"
cmp -s "$BASE/GOLDEN.ppm" "$BASE/typed.ppm" && {
  echo "  FAIL: keyboard not reactive"
  exit 1
} || echo "  OK: keyboard reactive"
$DRIVE loadvm golden sleep 2 shot "$BASE/restored.ppm"
frame_equal_or_caret "$BASE/GOLDEN.ppm" "$BASE/restored.ppm" && echo "  OK: loadvm golden == fixture" || {
  echo "  FAIL: loadvm mismatch"
  exit 1
}

echo "[bake] kill setup qemu (by pidfile); consistent golden-disk backup for NVMe rebuild"
kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 2
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
rm -f "$DISK.pre-savevm"
cp --reflink=auto "$DISK" "$DISK.bak-$(date +%Y%m%d)"
qemu-img snapshot -l "$DISK"
echo "[bake] done. Production launch auto -loadvm golden:  bash $BASE/qemu-streamhost.sh"
