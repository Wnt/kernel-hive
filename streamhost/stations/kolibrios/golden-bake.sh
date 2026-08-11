#!/bin/bash
# ============================================================================
# golden-bake.sh -- rebuild the 'kolibrios' GOLDEN test fixture from scratch.
# Boots the LiveCD headless (-display none), waits on its real framebuffer over QMP,
# and captures the live 'golden' snapshot into state.qcow2. Idempotent: recreates
# state.qcow2 from the empty base each run. Kill only by pidfile.
#
# Fixture: clean self-booted KolibriOS desktop. The nightly's taskbar clock/CPU
# meter animate, so reset proof uses a bounded pixel delta rather than a brittle
# whole-frame hash. KFM2 at (33,26) is opened only to dirty the proof frame.
# resetMode=loadvm.
# ============================================================================
set -e
BASE="${TILE_DIR:-/data/vms/streamhost/stations/kolibrios}"
Q="python3 $BASE/kolmouse.py $BASE/qmp.sock"

stop_qemu() {
  if [ -f "$BASE/qemu.pid" ]; then
    p="$(cat "$BASE/qemu.pid" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      kill -TERM "$p" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$p" 2>/dev/null || break
        sleep 0.25
      done
      kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
    fi
  fi
  rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
}

frame_is_desktop() {
  python3 - "$1" <<'PYFRAME'
import sys

with open(sys.argv[1], "rb") as f:
    data = f.read()
lines = data.split(b"\n", 3)
if len(lines) != 4 or lines[0] != b"P6" or lines[1] != b"1024 768" or lines[2] != b"255":
    raise SystemExit(1)
pixels = lines[3]
seen = set()
total = 0
count = 0
for i in range(0, max(0, len(pixels) - 3), 3 * 97):
    r, g, b = pixels[i], pixels[i + 1], pixels[i + 2]
    seen.add((r >> 4, g >> 4, b >> 4))
    total += r + g + b
    count += 1
mean = total / (3 * count) if count else 0
raise SystemExit(0 if len(seen) >= 8 and mean > 8 else 1)
PYFRAME
}

echo "== stop streamhost + any running qemu (by pidfile) =="
systemctl stop streamhost@kolibrios 2>/dev/null || true
stop_qemu
trap stop_qemu EXIT

echo "== fresh empty state disk =="
cp "$BASE/state.qcow2.base-empty" "$BASE/state.qcow2"

echo "== boot LiveCD headless (setup launcher) =="
bash "$BASE/qemu-setup.sh"

echo "== wait for the real desktop framebuffer (1024x768, colored, non-black) =="
desktop=0
for _ in $(seq 1 30); do
  $Q shot "$BASE/bake_boot_probe.ppm"
  if frame_is_desktop "$BASE/bake_boot_probe.ppm"; then
    desktop=1
    break
  fi
  sleep 1
done
[ "$desktop" = 1 ] || {
  echo "desktop framebuffer did not arrive within 30s" >&2
  exit 1
}
rm -f "$BASE/bake_boot_probe.ppm"
sleep 2

echo "== savevm golden =="
$Q savevm golden
$Q querysnap
qemu-img snapshot -l "$BASE/state.qcow2" | awk '{print $2}' | grep -qx golden

echo "== verify loadvm golden removes a deliberately opened KFM2 window =="
$Q loadvm golden sleep 0.2 shot "$BASE/bake_golden.ppm"
$Q move 33 26 click sleep 0.2 click sleep 1.0 shot "$BASE/bake_dirty.ppm"
$Q loadvm golden sleep 0.2 shot "$BASE/bake_reset.ppm"

python3 - "$BASE/bake_golden.ppm" "$BASE/bake_dirty.ppm" "$BASE/bake_reset.ppm" <<'PYFRAME'
import sys

def pixels(path):
    with open(path, "rb") as f:
        data = f.read()
    tokens = []
    i = 0
    while len(tokens) < 4:
        while data[i] in b" \t\r\n":
            i += 1
        j = i
        while data[j] not in b" \t\r\n":
            j += 1
        tokens.append(data[i:j])
        i = j
    while data[i] in b" \t\r\n":
        i += 1
    if tokens[0] != b"P6" or tokens[3] != b"255":
        raise SystemExit("unexpected PPM format")
    return (int(tokens[1]), int(tokens[2]), data[i:])

golden = pixels(sys.argv[1])
dirty = pixels(sys.argv[2])
reset = pixels(sys.argv[3])
if golden[:2] != dirty[:2] or golden[:2] != reset[:2]:
    raise SystemExit("frame dimensions changed during loadvm proof")

def delta(a, b):
    pa, pb = a[2], b[2]
    total = len(pa) // 3
    changed = sum(pa[i:i+3] != pb[i:i+3] for i in range(0, len(pa), 3))
    return changed / total

dirty_delta = delta(golden, dirty)
reset_delta = delta(golden, reset)
print(f"frame delta: dirty={dirty_delta:.6f} reset={reset_delta:.6f}")
if dirty_delta < 0.05:
    raise SystemExit("dirty frame did not visibly leave the golden desktop")
if reset_delta > 0.02:
    raise SystemExit("loadvm golden did not visibly restore the desktop")
PYFRAME

install -m 0644 "$BASE/bake_reset.ppm" /data/gallery-guests/KolibriOS/kolibri-golden.ppm
rm -f "$BASE/bake_golden.ppm" "$BASE/bake_dirty.ppm" "$BASE/bake_reset.ppm"

echo "== verified golden; stopping setup qemu by pidfile =="
stop_qemu
trap - EXIT
