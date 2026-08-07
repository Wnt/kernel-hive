#!/bin/bash
# Launch the same lively, keyboard-ready rio fixture used by the production
# golden. This runs only against record-boot.sh's copied disk/QMP clone.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bootrec-lib.sh disable=SC1091
source "${BOOTREC_LIB:-$HERE/bootrec-lib.sh}"

QMP="${1:?qmp.sock required}"
WORK="${2:?workdir required}/ninefront-driver"
# 1920x1080 curated fixture (must match scripts/build-guests/9front.sh FIXTURE_COMMAND
# and the golden geometry, or the boot-video->live-golden seam breaks).
FIXTURE_COMMAND="window -r 20 130 1250 1050 acme; window -r 1268 130 1900 430 stats; window -r 1268 442 1900 770 games/catclock; window -r 1268 782 1900 1050"
# Golden pointer-park (matches 9front.sh PARK_X/PARK_Y); reached over the clone's
# warpd hostfwd so the boot video's last frame is seam-identical to loadvm golden.
PARK_X=1580
PARK_Y=916
WARPD_CLONE_PORT="${BR_HOSTFWD_CLONE:-58793}"
mkdir -p "$WORK"

frame_matches() {
  local mode="$1" ppm="$2"
  python3 - "$mode" "$ppm" <<'PY'
import sys
mode, path = sys.argv[1:3]
d = open(path, "rb").read()
i = 2
vals = []
while len(vals) < 3:
    while i < len(d) and d[i] in b" \t\r\n":
        i += 1
    if d[i:i+1] == b"#":
        while i < len(d) and d[i] != 10:
            i += 1
        continue
    j = i
    while j < len(d) and d[j] not in b" \t\r\n":
        j += 1
    vals.append(int(d[i:j]))
    i = j
while i < len(d) and d[i] in b" \t\r\n":
    i += 1
w, h, mx = vals
if (w, h, mx) != (1920, 1080, 255):
    raise SystemExit(1)
px = d[i:i+w*h*3]
def at(x, y):
    o = (y*w+x)*3
    return tuple(px[o:o+3])
def white(c):
    return min(c) >= 235
def grey(c):
    return max(c)-min(c) <= 6 and 100 <= sum(c)/3 <= 145
def yellow(c):
    return c[0] >= 245 and c[1] >= 245 and 200 <= c[2] <= 245
def pink(c):
    return c[0] >= 245 and 200 <= c[1] <= 245 and 200 <= c[2] <= 245
if mode == "rio":
    # stock riostart: grey floor (lower-right, empty) + white boot term body.
    ok = all(grey(at(x, y)) for x, y in ((w-100,h-100),(w-300,h-300),(w-100,h//2)))
    ok = ok and all(white(at(x, y)) for x, y in ((100,200),(300,300),(500,400)))
else:
    # acme white body + yellow dir col, stats/load (pink), catclock + term (white),
    # grey rio floor below all windows.
    ok = white(at(300,600)) and yellow(at(1000,400))
    ok = ok and pink(at(1500,380)) and white(at(1300,500))
    ok = ok and white(at(1400,850)) and grey(at(960,1068))
raise SystemExit(0 if ok else 1)
PY
}

# Wait on framebuffer truth instead of a fixed boot delay. The cold source disk
# is slower than the old 1.449-second snapshot, so allow the arm's full bound.
rio=0
for i in $(seq 1 80); do
  shot="$WORK/rio-$i.ppm"
  br_screendump "$QMP" "$shot" || {
    sleep 1
    continue
  }
  sleep 0.15
  if frame_matches rio "$shot"; then
    rio=1
    break
  fi
  sleep 0.85
done
[ "$rio" -eq 1 ] || br_die "ninefront driver: rio framebuffer not reached"

# Fresh rio has no focused keyboard target. Home the relative PS/2 mouse, click
# the initial terminal, then type with the short hold/spacing 9front requires.
for _ in $(seq 1 12); do br_hmp "$QMP" 'mouse_move -100 -100' >/dev/null; done
br_hmp "$QMP" 'mouse_move 100 200' >/dev/null
br_hmp "$QMP" 'mouse_button 1' >/dev/null
br_hmp "$QMP" 'mouse_button 0' >/dev/null
sleep 0.5

python3 - "$QMP" "$FIXTURE_COMMAND" <<'PY'
import json, socket, sys, time
sock, text = sys.argv[1:3]
s = socket.socket(socket.AF_UNIX)
s.settimeout(30)
s.connect(sock)
f = s.makefile("rwb", buffering=0)
json.loads(f.readline())
def command(obj):
    f.write(json.dumps(obj).encode() + b"\n")
    while True:
        reply = json.loads(f.readline())
        if "event" in reply:
            continue
        if "error" in reply:
            raise SystemExit(reply["error"])
        if "return" in reply:
            return reply["return"]
command({"execute": "qmp_capabilities"})
plain = {
    " ": "spc", "-": "minus", ";": "semicolon", "/": "slash",
}
for char in text:
    keys = [char.lower()] if char.isalpha() or char.isdigit() else [plain[char]]
    command({"execute": "send-key", "arguments": {
        "keys": [{"type": "qcode", "data": key} for key in keys],
        "hold-time": 20,
    }})
    time.sleep(.060)
command({"execute": "send-key", "arguments": {
    "keys": [{"type": "qcode", "data": "ret"}], "hold-time": 20,
}})
PY

fixture=0
for i in $(seq 1 30); do
  shot="$WORK/fixture-$i.ppm"
  br_screendump "$QMP" "$shot" || {
    sleep 1
    continue
  }
  sleep 0.15
  if frame_matches fixture "$shot"; then
    cp -f "$shot" "$WORK/ready.ppm"
    fixture=1
    break
  fi
  sleep 0.85
done
[ "$fixture" -eq 1 ] || br_die "ninefront driver: lively rio fixture did not settle"

# Park the pointer at the golden's position via the clone's warpd hostfwd. Q both
# proves the agent is live and emits the move, so the boot video's final frame
# lands the cursor exactly where loadvm golden does (seam-identical, SSIM ~= 1).
parked=0
for _ in $(seq 1 20); do
  if python3 - "$WARPD_CLONE_PORT" "$PARK_X" "$PARK_Y" <<'PY'; then
import socket, sys
try:
    s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
    s.sendall(("Q %s %s\n" % (sys.argv[2], sys.argv[3])).encode())
    r = s.recv(16)
    s.close()
except OSError:
    raise SystemExit(1)
raise SystemExit(0 if r.strip() == b"K" else 1)
PY
    parked=1
    break
  fi
  sleep 1
done
[ "$parked" -eq 1 ] || br_die "ninefront driver: could not park pointer via warpd :$WARPD_CLONE_PORT"
sleep 0.3
br_log "ninefront driver: acme + stats + catclock + focused terminal + parked pointer ready"
