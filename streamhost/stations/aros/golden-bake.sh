#!/usr/bin/env bash
# Rebuild aros/golden-scratch.qcow2 from a cold AROS LiveCD boot. The
# production launcher and this setup QEMU intentionally use the same emulated
# device tree; only the display/audio host backends differ. The framebuffer is
# gated twice: first on Wanderer, then on the open AROS Shell saved as `golden`.
# No old-pool image is consulted. Kill QEMU only through this tile's pidfile.
set -euo pipefail

BASE="${TILE_DIR:-/data/vms/streamhost/tiles/aros}"
ISO="${AROS_ISO:-/data/gallery-guests/AmigaOS/aros-pc-i386.iso}"
PROOF_DIR="${PROOF_DIR:-/data/gallery-guests/AmigaOS}"
DISK="$BASE/golden-scratch.qcow2"
BAKE_DISK="$BASE/.golden-scratch.qcow2.bake.$$"
QMP="$BASE/qmp.sock"
PIDFILE="$BASE/qemu.pid"
VNC="$BASE/vnc.sock"
MACHINE="pc-i440fx-11.0"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-120}"
SHELL_TIMEOUT="${SHELL_TIMEOUT:-20}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
KEEP_BAKE=0

stop_qemu() {
  if [ -f "$PIDFILE" ]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      kill -TERM "$p" 2>/dev/null || true
      for _ in $(seq 1 40); do
        kill -0 "$p" 2>/dev/null || break
        sleep 0.25
      done
      kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
    fi
  fi
  rm -f "$QMP" "$PIDFILE" "$VNC"
}

cleanup() {
  stop_qemu
  [ "$KEEP_BAKE" = 1 ] || rm -f "$BAKE_DISK"
}
trap cleanup EXIT

qmp() {
  python3 - "$QMP" "$@" <<'PYQMP'
import json, socket, sys, time

sock, op, args = sys.argv[1], sys.argv[2], sys.argv[3:]
s = socket.socket(socket.AF_UNIX)
s.settimeout(30)
s.connect(sock)
f = s.makefile("rwb", buffering=0)
json.loads(f.readline())

def command(obj):
    f.write(json.dumps(obj).encode() + b"\n")
    while True:
        reply = json.loads(f.readline())
        if "error" in reply:
            raise SystemExit("QMP error: " + json.dumps(reply["error"]))
        if "return" in reply:
            return reply["return"]

command({"execute": "qmp_capabilities"})

def send_key(keys):
    command({"execute": "send-key", "arguments": {
        "keys": [{"type": "qcode", "data": key} for key in keys]
    }})
    time.sleep(.06)

if op == "shot":
    command({"execute": "screendump", "arguments": {"filename": args[0]}})
elif op == "hmp":
    out = command({"execute": "human-monitor-command", "arguments": {"command-line": args[0]}})
    if out:
        print(out, end="")
elif op == "key":
    send_key(args)
elif op == "type":
    plain = {" ": "spc", "-": "minus", ".": "dot", "/": "slash"}
    for char in args[0]:
        if char.isalpha() or char.isdigit():
            send_key([char.lower()])
        elif char in plain:
            send_key([plain[char]])
        else:
            raise SystemExit("unsupported fixture character: " + repr(char))
elif op == "abs":
    command({"execute": "input-send-event", "arguments": {"events": [
        {"type": "abs", "data": {"axis": "x", "value": int(args[0])}},
        {"type": "abs", "data": {"axis": "y", "value": int(args[1])}},
    ]}})
elif op == "require_abs":
    mice = command({"execute": "query-mice"})
    current = next((mouse for mouse in mice if mouse.get("current")), None)
    if not current or not current.get("absolute") or "Tablet" not in current.get("name", ""):
        raise SystemExit("QEMU HID Tablet is not AROS's active absolute pointer: " + repr(mice))
    print("[aros-bake] active pointer: " + repr(current))
else:
    raise SystemExit("unknown QMP operation: " + op)
s.close()
PYQMP
}

frame_is() {
  python3 - "$1" "$2" <<'PYFRAME'
import sys

path, wanted = sys.argv[1], sys.argv[2]
data = open(path, "rb").read()
tokens = []
i = 0
while len(tokens) < 4:
    while i < len(data) and data[i] in b" \t\r\n":
        i += 1
    j = i
    while j < len(data) and data[j] not in b" \t\r\n":
        j += 1
    tokens.append(data[i:j])
    i = j
while i < len(data) and data[i] in b" \t\r\n":
    i += 1
if tokens != [b"P6", b"1024", b"768", b"255"]:
    raise SystemExit(1)
pixels = data[i:]
if len(pixels) != 1024 * 768 * 3:
    raise SystemExit(1)

def at(x, y):
    p = (y * 1024 + x) * 3
    return tuple(pixels[p:p + 3])

# Wanderer's pale top bar plus three stable backdrop samples distinguish the
# desktop from GRUB, boot text, and blank/firmware frames.
top = at(500, 8)
backdrop = (at(100, 300), at(900, 700), at(790, 200))
desktop = all(v >= 225 for v in top) and all(sum(p) >= 160 for p in backdrop)
if wanted == "desktop":
    raise SystemExit(0 if desktop else 1)

# The saved fixture has AROS-Shell covering x=10..648/y=51..529. Its work
# area is the exact neutral grey below; requiring a broad majority makes this a
# semantic Shell-window gate without depending on transient cursor pixels.
grey = total = 0
for y in range(90, 500, 4):
    for x in range(25, 625, 4):
        r, g, b = at(x, y)
        total += 1
        grey += abs(r - g) <= 2 and abs(g - b) <= 2 and 145 <= r <= 160
shell = desktop and grey / total >= .88
raise SystemExit(0 if wanted == "shell" and shell else 1)
PYFRAME
}

pixel_delta() {
  python3 - "$1" "$2" <<'PYDELTA'
import sys

def pixels(path):
    data = open(path, "rb").read()
    i = 0
    for _ in range(4):
        while data[i] in b" \t\r\n": i += 1
        while data[i] not in b" \t\r\n": i += 1
    while data[i] in b" \t\r\n": i += 1
    return data[i:]

a, b = pixels(sys.argv[1]), pixels(sys.argv[2])
if len(a) != len(b):
    raise SystemExit("frame sizes differ")
changed = sum(a[i:i+3] != b[i:i+3] for i in range(0, len(a), 3))
print(changed / (len(a) // 3))
PYDELTA
}

[ -s "$ISO" ] || {
  echo "AROS ISO missing: $ISO" >&2
  exit 1
}
command -v "$QEMU_BIN" >/dev/null 2>&1 || {
  echo "QEMU missing: $QEMU_BIN" >&2
  exit 1
}
command -v qemu-img >/dev/null 2>&1 || {
  echo "qemu-img is required" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required" >&2
  exit 1
}
mkdir -p "$BASE" "$PROOF_DIR"

if [ "$BASE" = /data/vms/streamhost/tiles/aros ]; then
  systemctl stop streamhost@aros 2>/dev/null || true
fi
stop_qemu

echo "[aros-bake] create a fresh 1 GiB qcow2 (no backing file)"
rm -f "$BAKE_DISK"
qemu-img create -f qcow2 "$BAKE_DISK" 1G >/dev/null

echo "[aros-bake] cold boot under $MACHINE"
nice -n15 "$QEMU_BIN" \
  -name aros-golden-bake \
  -enable-kvm -m 512 -smp 1 \
  -machine "$MACHINE" -cpu host \
  -rtc base=localtime \
  -cdrom "$ISO" -boot d \
  -drive "file=$BAKE_DISK,format=qcow2,if=ide,index=0,media=disk" \
  -vga std \
  -usb -device usb-tablet,id=tab0 \
  -display none -vnc "unix:$VNC" \
  -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
  -qmp "unix:$QMP,server=on,wait=off" \
  -pidfile "$PIDFILE" \
  >"$BASE/golden-bake.log" 2>&1 &

for _ in $(seq 1 40); do
  [ -S "$QMP" ] && [ -f "$PIDFILE" ] && break
  sleep 0.5
done
[ -S "$QMP" ] && [ -f "$PIDFILE" ] || {
  echo "QEMU/QMP did not start" >&2
  exit 1
}

echo "[aros-bake] framebuffer gate: Wanderer desktop"
desktop=0
for _ in $(seq 1 "$BOOT_TIMEOUT"); do
  qmp shot "$BASE/bake-boot.ppm" 2>/dev/null || true
  if [ -s "$BASE/bake-boot.ppm" ] && frame_is "$BASE/bake-boot.ppm" desktop; then
    desktop=1
    break
  fi
  sleep 1
done
[ "$desktop" = 1 ] || {
  echo "Wanderer framebuffer did not arrive in ${BOOT_TIMEOUT}s" >&2
  exit 1
}

echo "[aros-bake] open AROS Shell: Right-Amiga+E, newshell, Enter"
qmp key meta_r e
sleep 0.5
qmp type newshell
qmp key ret
shell=0
for _ in $(seq 1 "$SHELL_TIMEOUT"); do
  qmp shot "$BASE/bake-golden.ppm"
  if frame_is "$BASE/bake-golden.ppm" shell; then
    shell=1
    break
  fi
  sleep 1
done
[ "$shell" = 1 ] || {
  echo "AROS Shell framebuffer did not arrive in ${SHELL_TIMEOUT}s" >&2
  exit 1
}

echo "[aros-bake] bind QEMU USB Tablet: AddUSBHardware pciusb.device 0"
qmp type "addusbhardware pciusb.device 0"
qmp key ret
# Poseidon's informational binding popup is transient. Let it retract before
# capturing the fixture, then require that AROS has switched away from PS/2.
sleep 6
qmp require_abs

echo "[aros-bake] framebuffer proof: absolute tablet reaches corners + centre"
for point in tl:3277:3277 tr:29490:3277 bl:3277:29490 br:29490:29490 center:16384:16384; do
  IFS=: read -r name x y <<<"$point"
  qmp abs "$x" "$y"
  sleep 0.2
  qmp shot "$PROOF_DIR/aros-abs-${name}.ppm"
done
frame_is "$PROOF_DIR/aros-abs-center.ppm" shell
# The snapshot includes the AddUSBHardware output above. Refresh the canonical
# comparison frame now so the later loadvm delta measures like-for-like state.
qmp shot "$BASE/bake-golden.ppm"

echo "[aros-bake] savevm golden"
qmp hmp "savevm golden"
qmp hmp "info snapshots" | tee "$BASE/golden-bake.snapshots"
grep -qw golden "$BASE/golden-bake.snapshots"

echo "[aros-bake] dirty the frame, then prove loadvm restores the Shell"
qmp type dir
qmp key ret
sleep 1
qmp shot "$BASE/bake-dirty.ppm"
qmp hmp "loadvm golden"
sleep 1
qmp require_abs
qmp shot "$BASE/bake-reset.ppm"
frame_is "$BASE/bake-reset.ppm" shell
dirty_delta="$(pixel_delta "$BASE/bake-golden.ppm" "$BASE/bake-dirty.ppm")"
reset_delta="$(pixel_delta "$BASE/bake-golden.ppm" "$BASE/bake-reset.ppm")"
python3 - "$dirty_delta" "$reset_delta" <<'PYVERIFY'
import sys
dirty, reset = map(float, sys.argv[1:])
print(f"[aros-bake] frame delta: dirty={dirty:.6f} reset={reset:.6f}")
if dirty < .002:
    raise SystemExit("dirty frame did not visibly leave the golden Shell")
if reset > .002:
    raise SystemExit("loadvm did not restore the golden Shell framebuffer")
PYVERIFY

stop_qemu
qemu-img snapshot -l "$BAKE_DISK" | awk '{print $2}' | grep -qx golden
if qemu-img info "$BAKE_DISK" | grep -q '^backing file:'; then
  echo "fresh golden unexpectedly has a backing file" >&2
  exit 1
fi

mv -f "$BAKE_DISK" "$DISK"
chmod 0644 "$DISK"
install -m 0644 "$BASE/bake-reset.ppm" "$PROOF_DIR/aros-golden.ppm"
KEEP_BAKE=1
rm -f "$BASE/bake-boot.ppm" "$BASE/bake-golden.ppm" "$BASE/bake-dirty.ppm" "$BASE/bake-reset.ppm"
echo "[aros-bake] PASS: fresh $DISK contains snapshot golden under $MACHINE"
