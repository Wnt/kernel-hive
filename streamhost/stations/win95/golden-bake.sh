#!/bin/bash
# (Re)bake the 'golden' snapshot for tile win95 from a COLD Win95 OSR2 boot.
# Use after a bare-metal/NVMe rebuild that wiped win95-golden.qcow2. FAST PATH is
# instead to ship win95-golden.qcow2.bak-20260706 as win95-golden.qcow2 and just
# run qemu-streamhost.sh (auto -loadvm golden). This script rebuilds from the
# PRISTINE shared gallery image.
#
# Win95 specifics baked here:
#   * warpnet.exe is cross-built from the vendored win9x source, injected as
#     C:\WARPNET.EXE, and auto-started by WIN.INI load= on every logon.
#   * WIN.INI is edited OFFLINE (run=notepad.exe auto-opens the reactive surface;
#     ScreenSaveActive=0 belt-and-suspenders). C:\NOBLINK.REG is dropped offline.
#   * Win95 IGNORES WIN.INI CursorBlinkRate and reads the registry value at LOGON,
#     so boot1 imports the long blink interval and boot2 applies it. Some OSR2
#     boots still toggle the 2x13 Notepad caret; framebuffer comparisons below
#     explicitly allow only that caret-sized delta and reject all other motion.
#   * The taskbar clock (per-minute HH:MM repaint) is hidden via Taskbar Properties.
# GUI is driven over QMP with screendump feedback; the keyboard-nav step counts
# match the OSR2 Start menu on this image (New/Open Office Document at the top).
# Kill only by pidfile.
set -e
BASE=/data/vms/streamhost/stations/win95
DISK="$BASE/win95-golden.qcow2"
SRC=/data/gallery-guests/Win95/win95-osr2-kvm.qcow2
BUILD_ROOT="${STREAMHOST_BUILD_ROOT:-/data/vms/streamhost/build}"
AGENT_DIR="$BUILD_ROOT/streamhost/guest-agents/win9x"
AGENT_EXE="$AGENT_DIR/warpnet.exe"
DRIVE="python3 $BASE/drive.py $BASE/qmp.sock"
NBD=/dev/nbd1
MNT=/mnt/win95g

grep -Eq -- '-machine pc-i440fx-[0-9]+\.[0-9]+,' "$BASE/qemu-streamhost.sh" || {
  echo "[bake] FAIL: launcher machine type is not pinned (emit with stations-manifest.sh --pin-machine)" >&2
  exit 1
}

echo "[bake] build the vendored Win95 warpnet agent"
nice -n 15 make -C "$BUILD_ROOT/streamhost/guest-agents" win9x
test -s "$AGENT_EXE"
sha256sum "$AGENT_EXE"

echo "[bake] stop service + win95 qemu (by pidfile), fresh golden disk from pristine source"
systemctl stop streamhost@win95
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 2
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
if [ -f "$DISK" ]; then
  cp --reflink=auto "$DISK" "$DISK.before-agent-bake-$(date +%Y%m%d-%H%M%S)"
fi
cp "$SRC" "$DISK"
cp "$DISK" "$DISK.pre-savevm" # backup before any savevm (rule)

echo "[bake] OFFLINE: inject WARPNET.EXE; WIN.INI load= autostart + fixture keys; drop C:\\NOBLINK.REG"
qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
sleep 1
qemu-nbd -c "$NBD" "$DISK"
sleep 2
mkdir -p "$MNT"
mount -t vfat "${NBD}p1" "$MNT"
cp "$AGENT_EXE" "$MNT/WARPNET.EXE"
python3 - "$MNT/WINDOWS/WIN.INI" <<'PY'
import sys
p=sys.argv[1]; lines=open(p,'rb').read().decode('latin-1').split('\r\n')
out=[]; inw=False; done=False; have=set()
for ln in lines:
    s=ln.strip().lower()
    if s.startswith('[') and s.endswith(']'):
        if inw and not done:
            for k,v in [('load',r'C:\WARPNET.EXE'),('ScreenSaveActive','0'),('ScreenSaveTimeOut','0')]:
                if k.lower() not in have: out.append('%s=%s'%(k,v))
            done=True
        inw=(s=='[windows]')
    if inw and s.startswith('run='): out.append('run=notepad.exe'); have.add('run'); continue
    if inw and s.startswith('load='): out.append(r'load=C:\WARPNET.EXE'); have.add('load'); continue
    if inw and '=' in s: have.add(s.split('=',1)[0])
    out.append(ln)
open(p,'wb').write('\r\n'.join(out).encode('latin-1'))
print(r'  WIN.INI patched: load=C:\WARPNET.EXE')
PY
printf 'REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Control Panel\\Desktop]\r\n"CursorBlinkRate"="2000000000"\r\n' >"$MNT/NOBLINK.REG"
test -s "$MNT/WARPNET.EXE"
sync
umount "$MNT"
qemu-nbd -d "$NBD" >/dev/null 2>&1
sleep 1

echo "[bake] BOOT 1 (cold) -- dismiss network dialog, wait for desktop + auto-Notepad"
bash "$BASE/qemu-streamhost.sh" # no snapshot yet => cold boot
$DRIVE sleep 45 key ret sleep 35 shot "$BASE/bake_b1.ppm"

echo "[bake] import the blink registry value (applied at NEXT logon)"
$DRIVE kc c esc sleep 1 key r sleep 1 type 'regedit /s c:\NOBLINK.REG' key ret sleep 2

echo "[bake] hide the taskbar clock (Start > Settings > Taskbar > Show Clock OFF)"
$DRIVE kc c esc sleep 1 key down down down down down sleep 0.4 key right sleep 0.6 key down down sleep 0.3 key ret sleep 2
$DRIVE key tab tab tab sleep 0.3 key spc sleep 0.4 key ret sleep 1.5 shot "$BASE/bake_clock.ppm"

echo "[bake] REBOOT so logon reads the long caret-blink interval"
$DRIVE kc c esc sleep 1 key up sleep 0.3 key ret sleep 2.5 key down sleep 0.3 key ret sleep 55

echo "[bake] BOOT 2 -- dismiss network dialog, wait for desktop + auto-Notepad (long caret interval, clock hidden)"
$DRIVE key ret sleep 35 shot "$BASE/bake_b2.ppm"

echo "[bake] maximize Notepad + park caret visible"
$DRIVE kc a spc sleep 0.8 key x sleep 1.5 key home sleep 0.5

frame_equal_or_caret() {
  python3 - "$1" "$2" <<'PY'
import sys
def ppm(path):
    raw=open(path,'rb').read()
    magic,w,h,maxv,pixels=raw.split(None,4)
    assert magic==b'P6' and maxv==b'255'
    return int(w),int(h),pixels
w,h,a=ppm(sys.argv[1]); w2,h2,b=ppm(sys.argv[2])
assert (w,h)==(w2,h2)
pts=[(i%w,i//w) for i in range(w*h) if a[i*3:i*3+3] != b[i*3:i*3+3]]
if not pts:
    print('identical')
    raise SystemExit(0)
x0,y0=min(x for x,y in pts),min(y for x,y in pts)
x1,y1=max(x for x,y in pts),max(y for x,y in pts)
if len(pts)<=60 and x1-x0+1<=3 and y1-y0+1<=20:
    print('caret-only: changed=%d bbox=(%d,%d)-(%d,%d)'%(len(pts),x0,y0,x1,y1))
    raise SystemExit(0)
print('unexpected motion: changed=%d bbox=(%d,%d)-(%d,%d)'%(len(pts),x0,y0,x1,y1))
raise SystemExit(1)
PY
}

echo "[bake] prove the auto-started agent at two exact coordinates"
timeout 5 bash -c "printf 'M 97 151\\n' >/dev/tcp/127.0.0.1/57791"
$DRIVE sleep 0.4 shot "$BASE/warp_probe_97_151.ppm"
timeout 5 bash -c "printf 'M 503 307\\n' >/dev/tcp/127.0.0.1/57791"
$DRIVE sleep 0.4 shot "$BASE/warp_probe_503_307.ppm"
python3 - "$BASE/warp_probe_97_151.ppm" "$BASE/warp_probe_503_307.ppm" <<'PY'
import sys
def ppm(path):
    raw=open(path,'rb').read()
    magic,w,h,maxv,pixels=raw.split(None,4)
    assert magic==b'P6' and maxv==b'255'
    return int(w),int(h),pixels
w,h,a=ppm(sys.argv[1]); w2,h2,b=ppm(sys.argv[2])
assert (w,h)==(w2,h2)==(640,480)
changed=[]
for i in range(w*h):
    if a[i*3:i*3+3] != b[i*3:i*3+3]: changed.append((i%w,i//w))
def near(x,y): return sum(abs(px-x)<=16 and abs(py-y)<=16 for px,py in changed)
na,nb=near(97,151),near(503,307)
assert na and nb, 'cursor delta missing at commanded coordinates: nearA=%d nearB=%d'%(na,nb)
print('  PROBE PASS: M 97 151 -> M 503 307; changed=%d nearA=%d nearB=%d'%(len(changed),na,nb))
PY
timeout 5 bash -c "printf 'M 320 240\\n' >/dev/tcp/127.0.0.1/57791"
$DRIVE sleep 0.4

echo "[bake] determinism check: 6 idle screendumps (identical or caret-only delta)"
$DRIVE shot "$BASE/g0.ppm" sleep 2 shot "$BASE/g1.ppm" sleep 2 shot "$BASE/g2.ppm" sleep 2 shot "$BASE/g3.ppm" sleep 2 shot "$BASE/g4.ppm" sleep 2 shot "$BASE/g5.ppm"
for f in g1 g2 g3 g4 g5; do frame_equal_or_caret "$BASE/g0.ppm" "$BASE/$f.ppm" || {
  echo "  FAIL: idle animation beyond caret ($f)"
  exit 1
}; done
echo "  OK: no idle animation beyond the Notepad caret over ~10s"

echo "[bake] savevm golden"
$DRIVE delvm golden >/dev/null 2>&1 || true
$DRIVE shot "$BASE/GOLDEN.ppm" savevm golden sleep 1 querysnap

echo "[bake] verify reactive + loadvm (type -> differs -> loadvm -> byte-identical)"
$DRIVE type 'HELLO WIN95 GOLDEN FIXTURE' sleep 0.5 shot "$BASE/typed.ppm"
cmp -s "$BASE/GOLDEN.ppm" "$BASE/typed.ppm" && {
  echo "  FAIL: keyboard not reactive"
  exit 1
} || echo "  OK: keyboard reactive"
$DRIVE loadvm golden sleep 1 shot "$BASE/restored.ppm"
frame_equal_or_caret "$BASE/GOLDEN.ppm" "$BASE/restored.ppm" && echo "  OK: loadvm golden == fixture (apart from allowed caret phase)" || {
  echo "  FAIL: loadvm mismatch"
  exit 1
}

echo "[bake] kill setup qemu (by pidfile); consistent golden-disk backup for NVMe rebuild"
kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 2
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
cp "$DISK" "$DISK.bak-$(date +%Y%m%d)"
qemu-img snapshot -l "$DISK"
echo "[bake] done. Production launch auto -loadvm golden:  bash $BASE/qemu-streamhost.sh"
