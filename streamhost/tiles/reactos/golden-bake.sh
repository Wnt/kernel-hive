#!/usr/bin/env bash
# Rebuild ReactOS's savevm-backed golden fixture from the pinned LiveCD.
# The settings floppy is generated here, attached only during customization,
# and ejected before savevm so the runtime device set has an empty floppy0.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUEST_DIR="${GUEST_DIR:-/data/gallery-guests/ReactOS}"
REACTOS_ISO="${REACTOS_ISO:-$GUEST_DIR/ReactOS.iso}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
STORE="$GUEST_DIR/reactos-golden.qcow2"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/reactos-golden-bake.XXXXXX")"
QMP="$WORK/qmp.sock"
PIDFILE="$WORK/qemu.pid"
DRIVE=(python3 "$HERE/drive.py" "$QMP")
PROOF="$GUEST_DIR/reactos-golden.ppm"

stop_qemu() {
  if [ -f "$PIDFILE" ]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      "${DRIVE[@]}" hmp quit >/dev/null 2>&1 || kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
      done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$QMP" "$PIDFILE"
}
cleanup() {
  stop_qemu
  rm -rf "$WORK"
}
trap cleanup EXIT

frame_is_wizard() {
  python3 - "$1" <<'PY'
import sys

data = open(sys.argv[1], "rb").read()
head = data.split(b"\n", 3)
if len(head) != 4 or head[0] != b"P6" or head[1] != b"800 600" or head[2] != b"255":
    raise SystemExit(1)
pixels = head[3]
def pixel(x, y):
    i = (y * 800 + x) * 3
    return tuple(pixels[i:i + 3])
def blue(value):
    r, g, b = value
    return 30 <= r <= 90 and 70 <= g <= 150 and 120 <= b <= 220
def dialog(value):
    r, g, b = value
    return 180 <= r <= 235 and 180 <= g <= 235 and 175 <= b <= 230
# The real LiveCD wizard is the large centered dialog spanning x=159..638.
# This deliberately rejects the earlier small "Installing devices" dialog.
ok = blue(pixel(50, 50)) and dialog(pixel(170, 160)) and dialog(pixel(170, 400))
raise SystemExit(0 if ok else 1)
PY
}

frame_is_fixture_desktop() {
  python3 - "$1" <<'PY'
import sys

data = open(sys.argv[1], "rb").read()
head = data.split(b"\n", 3)
if len(head) != 4 or head[0] != b"P6" or head[1] != b"800 600" or head[2] != b"255":
    raise SystemExit(1)
pixels = head[3]
def pixel(x, y):
    i = (y * 800 + x) * 3
    return tuple(pixels[i:i + 3])
def blue(value):
    r, g, b = value
    return 30 <= r <= 90 and 70 <= g <= 150 and 120 <= b <= 220
def white(value):
    return min(value) >= 235
def taskbar(value):
    r, g, b = value
    return 180 <= r <= 235 and 180 <= g <= 235 and 175 <= b <= 230
ok = blue(pixel(650, 300)) and blue(pixel(700, 450))
ok = ok and white(pixel(300, 200)) and taskbar(pixel(400, 585))
# With the clock visible, the blue "EN" language button occupies x=727..746.
# Hiding it shifts the tray right and leaves taskbar gray at this pixel.
ok = ok and taskbar(pixel(740, 585))
raise SystemExit(0 if ok else 1)
PY
}

frame_is_plain_desktop() {
  python3 - "$1" <<'PY'
import sys
data = open(sys.argv[1], "rb").read().split(b"\n", 3)
if len(data) != 4 or data[:3] != [b"P6", b"800 600", b"255"]:
    raise SystemExit(1)
p = data[3]
def blue(x, y):
    i = (y * 800 + x) * 3
    r, g, b = p[i:i + 3]
    return 30 <= r <= 90 and 70 <= g <= 150 and 120 <= b <= 220
raise SystemExit(0 if blue(300, 200) and blue(650, 300) else 1)
PY
}

wait_for_frame() {
  local predicate="$1" label="$2" tries="$3" shot="$WORK/probe.ppm"
  for _ in $(seq 1 "$tries"); do
    "${DRIVE[@]}" shot "$shot" >/dev/null 2>&1 || true
    if [ -s "$shot" ] && "$predicate" "$shot"; then
      echo "[reactos-golden] framebuffer gate: $label"
      return 0
    fi
    sleep 2
  done
  echo "[reactos-golden] framebuffer gate timed out: $label" >&2
  return 1
}

echo "[reactos-golden] generating the settings floppy from source payloads"
FLOPPY="$WORK/g.img"
REG="$WORK/g.reg"
BAT="$WORK/g.bat"
truncate -s 1440K "$FLOPPY"
mformat -i "$FLOPPY" -f 1440 ::
printf '%s\r\n' \
  'Windows Registry Editor Version 5.00' '' \
  '[HKEY_CURRENT_USER\Control Panel\Desktop]' \
  '"ScreenSaveActive"="0"' \
  '"ScreenSaveTimeOut"="0"' \
  '"SCRNSAVE.EXE"=""' \
  '"PowerOffActive"="0"' \
  '"LowPowerActive"="0"' \
  '"PowerOffTimeOut"="0"' \
  '"LowPowerTimeOut"="0"' \
  '"CursorBlinkRate"="-1"' '' \
  '[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer]' \
  '"HideClock"=dword:00000001' >"$REG"
printf '%s\r\n' '@echo off' 'regedit /s A:\g.reg' 'start notepad.exe' >"$BAT"
mcopy -i "$FLOPPY" "$REG" ::g.reg
mcopy -i "$FLOPPY" "$BAT" ::g.bat
install -m 0644 "$FLOPPY" "$GUEST_DIR/reactos-settings.img"

echo "[reactos-golden] creating a fresh qcow2 snapshot store"
FRESH="$WORK/reactos-golden.qcow2"
qemu-img create -q -f qcow2 "$FRESH" 256M

echo "[reactos-golden] cold-booting pc-i440fx-11.0 with the runtime device set"
"$QEMU_BIN" \
  -name reactos-golden-bake \
  -enable-kvm -machine pc-i440fx-11.0 -cpu host -m 512 -smp 1 \
  -rtc base=localtime \
  -cdrom "$REACTOS_ISO" -boot d \
  -drive "file=$FRESH,if=ide,index=0,media=disk,format=qcow2" \
  -fda "$FLOPPY" \
  -vga std \
  -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -display none \
  -qmp "unix:$QMP,server=on,wait=off" \
  -pidfile "$PIDFILE" \
  >"$WORK/qemu.log" 2>&1 &

for _ in $(seq 1 40); do
  [ -S "$QMP" ] && [ -s "$PIDFILE" ] && break
  sleep 0.5
done
[ -S "$QMP" ] && [ -s "$PIDFILE" ] || {
  cat "$WORK/qemu.log" >&2
  exit 1
}

wait_for_frame frame_is_wizard "800x600 LiveCD wizard" 90
echo "[reactos-golden] driving LiveCD wizard: Enter, 6s, Enter, 18s"
"${DRIVE[@]}" key ret >/dev/null
sleep 6
"${DRIVE[@]}" key ret >/dev/null
sleep 18

echo "[reactos-golden] applying floppy customization and opening Notepad"
# Use the visible Start -> Run path; the Windows-key shortcut is not reliable.
wait_for_frame frame_is_plain_desktop "plain desktop after LiveCD wizard" 30
"${DRIVE[@]}" click 30 587 >/dev/null
sleep 1
"${DRIVE[@]}" click 80 484 >/dev/null
sleep 2
"${DRIVE[@]}" type cmd >/dev/null
"${DRIVE[@]}" key ret >/dev/null
sleep 3
"${DRIVE[@]}" type A: >/dev/null
"${DRIVE[@]}" key ret >/dev/null
"${DRIVE[@]}" type g.bat >/dev/null
"${DRIVE[@]}" key ret >/dev/null
sleep 5
"${DRIVE[@]}" key alt tab >/dev/null
sleep 1
"${DRIVE[@]}" type exit >/dev/null
"${DRIVE[@]}" key ret >/dev/null
sleep 2

echo "[reactos-golden] hiding the taskbar clock through Taskbar Properties"
"${DRIVE[@]}" click 500 587 right >/dev/null
sleep 2
"${DRIVE[@]}" key end >/dev/null
"${DRIVE[@]}" key ret >/dev/null
sleep 3
# Initial focus is "Lock the taskbar"; five Tabs reaches "Show clock".
for _ in 1 2 3 4 5; do "${DRIVE[@]}" key tab >/dev/null; done
"${DRIVE[@]}" key spc >/dev/null
"${DRIVE[@]}" key ret >/dev/null
sleep 3

echo "[reactos-golden] focusing empty Notepad and parking the pointer"
"${DRIVE[@]}" click 200 200 >/dev/null
"${DRIVE[@]}" move 405 480 >/dev/null
sleep 1
wait_for_frame frame_is_fixture_desktop "curated 800x600 ReactOS desktop" 30
"${DRIVE[@]}" shot "$WORK/golden.ppm" >/dev/null

echo "[reactos-golden] ejecting settings floppy and saving snapshot 'golden'"
"${DRIVE[@]}" hmp "eject floppy0" >/dev/null
"${DRIVE[@]}" hmp "savevm golden" >/dev/null
"${DRIVE[@]}" hmp "info snapshots"
qemu-img snapshot -l "$FRESH" | awk 'NR > 2 {print $2}' | grep -qx golden

echo "[reactos-golden] proving loadvm removes a typed dirty character"
"${DRIVE[@]}" click 200 200 >/dev/null
"${DRIVE[@]}" type x >/dev/null
sleep 1
"${DRIVE[@]}" shot "$WORK/dirty.ppm" >/dev/null
"${DRIVE[@]}" hmp "loadvm golden" >/dev/null
sleep 1
"${DRIVE[@]}" shot "$WORK/reset.ppm" >/dev/null
python3 - "$WORK/golden.ppm" "$WORK/dirty.ppm" "$WORK/reset.ppm" <<'PY'
import sys

def ppm(path):
    data = open(path, "rb").read().split(b"\n", 3)
    if data[:3] != [b"P6", b"800 600", b"255"]:
        raise SystemExit(f"unexpected framebuffer: {path}")
    return data[3]

golden, dirty, reset = map(ppm, sys.argv[1:])
def changed(a, b, x0, y0, x1, y1):
    count = total = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            i = (y * 800 + x) * 3
            count += a[i:i + 3] != b[i:i + 3]
            total += 1
    return count / total

dirty_delta = changed(golden, dirty, 8, 43, 130, 66)
reset_delta = changed(golden, reset, 8, 43, 130, 66)
print(f"[reactos-golden] Notepad ROI delta: dirty={dirty_delta:.6f} reset={reset_delta:.6f}")
if dirty_delta < 0.01:
    raise SystemExit("typed character did not visibly dirty Notepad")
if reset_delta > 0.01:
    raise SystemExit("loadvm did not restore the Notepad fixture")
PY

install -m 0644 "$WORK/reset.ppm" "$PROOF"
stop_qemu
mv -f "$FRESH" "$STORE"
cat >"$GUEST_DIR/golden-manifest.json" <<EOF
{
  "tile": "reactos",
  "os": "ReactOS 0.4.14 release-125-g5b02d38 LiveCD",
  "fixtureDescription": "800x600 desktop with focused empty Notepad, hidden clock, disabled screensaver and monitor power-off, and pointer parked on the blue desktop",
  "resetMode": "loadvm",
  "snapshot": "golden",
  "snapshotStore": "$STORE",
  "bakeMachine": "pc-i440fx-11.0",
  "bakeCpu": "host",
  "memoryMiB": 512,
  "devices": ["AC97", "usb-tablet"],
  "settingsFloppy": "generated by streamhost/tiles/reactos/golden-bake.sh and ejected before savevm",
  "provenance": "from pinned upstream LiveCD; no restored golden or /mnt/poc input"
}
EOF
echo "[reactos-golden] PASS: fresh $STORE contains snapshot 'golden'"
trap - EXIT
rm -rf "$WORK"
