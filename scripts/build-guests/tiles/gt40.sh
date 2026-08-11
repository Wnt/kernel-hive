#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/gt40.sh — build the DEC GT40 / VT11 "Lunar Lander" (1973)
# streamhost station as a thin overlay on the frozen bridge base
# (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-13 (trixie) kiosk running Open SIMH's `pdp11` with the VT11
#         vector display, executing the original 1973 GT40 Lunar Lander paper
#         tape. streamhost captures the Linux framebuffer like every other
#         kiosk (streamhost/docs/BRIDGE.md).
# TYPE  : "emulator bridge" station. Overlay + per-station /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- THE ONE DEVIATION FROM THE OTHER BRIDGE TILES --------------------------
#   The frozen bridge base ships five emulators and SIMH is not one of them, so
#   this script BUILDS OPEN SIMH INTO THE TILE OVERLAY — the amiga.sh precedent.
#   Nothing else is needed: the base already carries gcc, make, git, libsdl2-dev,
#   libpng-dev and libpcre2-dev, so `make pdp11` compiles with -DUSE_DISPLAY
#   -DHAVE_LIBSDL -DUSE_SIM_VIDEO out of the box, in 90 s. docs/guests/gt40.md
#   records the bridge-base.sh addition a from-scratch NVMe rebuild would need.
#   Debian's packaged simh is 3.8.1 built WITHOUT SDL video and is useless; the
#   pin is a COMMIT because there is no v4 release tag past v4.0-Beta-1.
#
# ---- ZERO EXTERNAL MEDIA, AND THE CLEANEST LICENCE STORY IN THE COLLECTION ---
#   `lunar.lda` — the 1973 paper tape itself — ships INSIDE the MIT-licensed
#   Open SIMH tree at PDP11/lunar11/. Nothing is fetched, staged or committed:
#   the exhibit's whole content arrives with the source the emulator is built
#   from, and its sha256 is asserted below so a moved pin cannot change it.
#
# ---- THE EXHIBIT: A MACHINE WITH NO KEYBOARD --------------------------------
#   The Lunar Lander uses the light pen for EVERYTHING: the twelve-item telemetry
#   menu, the four rotation arrows, the throttle bar you slide the pen along.
#   lunar.txt documents no key at all, so this station emits --pointer abs and NO
#   keyboard affordance. In Open SIMH the pen is mouse button 1 and nothing else
#   (display/sim_ws.c ws_poll: `display_lp_sw = mev.b1_state`): it is on the
#   glass only WHILE the button is held, at the position carried by that same
#   event. A press IS the gesture; there is no hover.
#
# ---- MEASUREMENTS THIS SCRIPT ENCODES (all taken on the box, 2026-08-09) -----
#   * `set vt crt=vr17` + `set vt hspace=narrow` — with vr14 the menu column is
#     clipped mid-word (ALTITUD, FUEL LEF). vr17 at scale=1 is a fixed 1024x1024
#     SDL window; xwininfo reports it at 1024x1024+128+0 on a 1280x1024 root, the
#     smallest mode the kiosk's bochs-drm advertises that contains it, and the
#     full twelve-item menu (HEIGHT … SECONDS) is unclipped.
#   * SDL_RENDER_DRIVER=software is kept because the kiosk has no GPU, but it is
#     NOT the win it is on the host: 184 % of a core without it, 177 % with it,
#     i.e. inside noise — only TWO llvmpipe workers ever spawn in a 2-vCPU guest
#     (the host, with sixteen, saw 205 % -> 118 %). LP_NUM_THREADS=0 removes the
#     threads and RAISES the total to 193 %, so it is deliberately NOT set: the
#     work is phosphor decay plus a 1 Mpixel software blit, and moving it onto
#     the emulator thread only starves it. `set throttle` is useless (the lander
#     busy-spins) and `set cpu idle` is a TERMINAL-ini knob with nothing to idle.
#
# ---- THE FIXTURE: THE FIRST SECONDS OF A FRESH DESCENT ----------------------
#   The exhibit is SELF-SUSTAINING: the LEM falls for ~2 minutes, crashes ("WELL,
#   YOU CERTAINLY BLEW THAT ONE. THERE WERE NO SURVIVORS"), holds that ~12 s and
#   RESTARTS ITSELF — a 135 s loop measured over a 300 s unattended run. That is
#   why the golden can rest on a moving screen, and it decides WHICH moment: the
#   bake waits for the crash message and then for the restart, so `loadvm golden`
#   always returns a visitor to 18000 feet with the whole arc ahead rather than
#   the middle of somebody else's doomed trajectory.
#
# HYGIENE: thin overlay, namespaced qmp.sock/pidfile, kills only by pidfile,
# idempotent, --force rebuilds. Touches ONLY the gt40 station dir; refuses to run
# while streamhost@gt40 is active.  Usage: gt40.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=gt40
VMID=228
UDP=54125
SSH_PORT=5828
WEB_PORT=8128
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/gt40
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
PEN="$TILE_DIR/pen-drive.py"
MEM=768
X_MODE=1280x1024

# Open SIMH master, 2026-07-03. There is no v4 release tag past v4.0-Beta-1, so
# the pin is a commit. lunar.lda is in-tree; its hash is the exhibit's identity.
SIMH_COMMIT=a1f57fa3738ed31148d31126ba1a7278ff845c6d
LUNAR_SHA256=95f314570424a2d3a5e5e4684b78d5b5f519d6f16931854540dc736220340930

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,66p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[gt40 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[gt40] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# The GT40 kiosk launcher. Unlike every other kiosk the core pointer is
# LEFT VISIBLE and the root is painted black: the pen is the machine's only
# input, and black root + black CRT read as one continuous screen.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# DEC GT40 / VT11 Lunar Lander kiosk launcher (kiosk).
# See scripts/build-guests/tiles/gt40.sh for the flag and measurement rationale.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 1280x1024 2>/dev/null || true
# The ROOT window's default cursor is the classic X "X". The pointer rests on
# the root in the baked fixture, so give the root the same arrow SIMH draws
# inside its window — otherwise the golden ships with an X in the corner.
xsetroot -solid black -cursor_name left_ptr 2>/dev/null || true
cd /opt/bridge/gt40
exec /opt/bridge/gt40/pdp11 /opt/bridge/gt40/gt40.ini
EOS

# The SIMH configuration, and every line is load-bearing:
#   11/70          a Unibus CPU, so the VT autoconfigures (PDP11/lunar11/README).
#                  NOT the GT40's own 11/05 — SIMH does not model that pairing.
#   dli enable/2   the DL11 the VT device's vector 320 is derived from
#   crt=vr17       1024x1024 points; vr14 CLIPS the menu column mid-word
#   hspace=narrow  the character spacing the 1973 menu was laid out for
#   dep 32530 1    README.txt's own trick: skips the spin-loop the tape uses to
#                  time its introductory message, which SIMH counts in
#                  instructions rather than time and would otherwise take
#                  "forever"
read -r -d '' INI <<'EOS' || true
set cpu 11/70
set cpu 128K
set dli enable
set dli line=2
set vt enable
set vt crt=vr17
set vt scale=1
set vt hspace=narrow
load /opt/bridge/gt40/lunar.lda
dep 32530 1
run
EOS

# Kiosk session profile. NOTE the missing -nocursor, which every other bridge
# station passes: this exhibit is pointer-only and the visitor needs to see where
# the pen is. stdout stays on tty1 (the base's own rule; VICE dies without it
# and SIMH has no reason to differ).
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (gt40 overlay). X keeps its core pointer cursor: the
# VT11 light pen is this machine's ONLY input device.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx
fi
EOS

read -r -d '' PEN_PY <<'EOS' || true
#!/usr/bin/env python3
"""Drive the GT40's LIGHT PEN, and measure the vector CRT, over the tile's QMP.

The VT11 pen is mouse button 1 and nothing else (display/sim_ws.c ws_poll:
`display_lp_sw = mev.b1_state`), so a pen touch is press-AT-a-point: move the
absolute tablet there, press, hold, release. Coordinates are ROOT pixels on the
1280x1024 kiosk screen; the VT11 window sits at +128+0.

  point <x> <y> [hold_s] | park <x> <y> | rect <l> <t> <w> <h>
  burst <n> <dt> <l> <t> <w> <h>   -> min/max/range of lit pixels
"""

import json
import os
import socket
import sys
import tempfile
import time

W, H = 1280, 1024
QMP = sys.argv[1]

sock = socket.socket(socket.AF_UNIX)
sock.settimeout(120)
sock.connect(QMP)
conn = sock.makefile("rwb")
conn.readline()

def cmd(execute, **args):
    payload = {"execute": execute}
    if args:
        payload["arguments"] = args
    conn.write((json.dumps(payload) + "\n").encode())
    conn.flush()
    while True:
        msg = json.loads(conn.readline())
        if "return" in msg or "error" in msg:
            return msg

cmd("qmp_capabilities")

def at(x, y):
    return [
        {"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / (W - 1))}},
        {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / (H - 1))}},
    ]

def point(x, y, hold):
    cmd("input-send-event", events=at(x, y))
    time.sleep(0.25)
    cmd("input-send-event", events=at(x, y) + [{"type": "btn", "data": {"down": True, "button": "left"}}])
    time.sleep(hold)
    cmd("input-send-event", events=[{"type": "btn", "data": {"down": False, "button": "left"}}])
    time.sleep(0.2)

def shot():
    path = tempfile.mktemp(suffix=".ppm")
    cmd("human-monitor-command", **{"command-line": "screendump " + path})
    with open(path, "rb") as fh:
        data = fh.read()
    os.unlink(path)
    return data

def lit(data, left, top, w, h):
    """Count phosphor-green pixels in a rect: 'the CRT is drawing here'."""
    hdr = data[:64].split(None, 4)
    iw, ih = int(hdr[1]), int(hdr[2])
    body = data[len(data) - iw * ih * 3 :]
    n = 0
    for row in range(top, min(top + h, ih)):
        base = (row * iw + left) * 3
        for col in range(left, min(left + w, iw)):
            off = base + (col - left) * 3
            if body[off + 1] > 60 and body[off] < 90 and body[off + 2] < 90:
                n += 1
    return n

mode = sys.argv[2]
if mode == "point":
    point(int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5]) if len(sys.argv) > 5 else 0.30)
elif mode == "park":
    cmd("input-send-event", events=at(int(sys.argv[3]), int(sys.argv[4])))
elif mode == "rect":
    print(lit(shot(), *(int(a) for a in sys.argv[3:7])))
elif mode == "burst":
    n, dt = int(sys.argv[3]), float(sys.argv[4])
    box = tuple(int(a) for a in sys.argv[5:9])
    vals = []
    for _ in range(n):
        vals.append(lit(shot(), *box))
        time.sleep(dt)
    print("min=%d max=%d range=%d %s" % (min(vals), max(vals), max(vals) - min(vals), vals))
else:
    raise SystemExit("unknown mode " + mode)
EOS

# --- rects on the 1280x1024 kiosk root (window origin +128+0) ----------------
# MENU:  the twelve-item telemetry column. Static unless an item is SELECTED, in
#        which case it blinks: measured range 0 idle, 376 with ANGLE selected.
# CRASH: the band the "NO SURVIVORS" message is drawn in. 214-258 quiescent, up
#        to ~2050 when the falling LEM crosses it, 3104 with the message up.
# LEM:   the box the module starts in, upper left, overlapping the readout row.
#        2046-2295 on a fresh descent, 505-833 at any other time.
RECT_MENU="1035 755 120 268"
RECT_CRASH="300 400 700 300"
RECT_LEM="140 250 220 110"
PEN_ANGLE="1070 901" # the ANGLE item in the menu column
PEN_PARK="8 8"       # the root, hard against the corner: no vector to select

install_simh() {
  guest "set -e
    mkdir -p /usr/local/src && cd /usr/local/src
    [ -d simh ] || git clone -q https://github.com/open-simh/simh.git
    cd simh
    git fetch -q --all 2>/dev/null || true
    git checkout -q $SIMH_COMMIT
    [ \"\$(git rev-parse HEAD)\" = $SIMH_COMMIT ] || { echo 'simh pin did not check out' >&2; exit 1; }
    if [ ! -x BIN/pdp11 ]; then
      make pdp11 -j2 > /tmp/simh-build.log 2>&1 || { tail -30 /tmp/simh-build.log >&2; exit 1; }
      grep -q -- '-DUSE_DISPLAY -DHAVE_LIBSDL -DUSE_SIM_VIDEO' /tmp/simh-build.log ||
        { echo 'pdp11 built WITHOUT the SDL vector display' >&2; exit 1; }
    fi
    echo \"$LUNAR_SHA256  PDP11/lunar11/lunar.lda\" | sha256sum -c - >/dev/null
    install -d -m 755 /opt/bridge/gt40
    install -m 755 BIN/pdp11 /opt/bridge/gt40/pdp11
    install -m 644 PDP11/lunar11/lunar.lda /opt/bridge/gt40/lunar.lda
    install -m 644 PDP11/lunar11/lunar.txt /opt/bridge/gt40/lunar.txt" ||
    die "could not build Open SIMH $SIMH_COMMIT with the VT11 display in the overlay"
  guest "/opt/bridge/gt40/pdp11 /dev/null 2>&1 | grep -q 'Open SIMH'" ||
    die "the built pdp11 does not run in the guest"
  log "Open SIMH ${SIMH_COMMIT:0:8} built into the overlay; lunar.lda sha256 verified"
}

quiet_console() {
  guest "set -e
    sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0 quiet loglevel=0 vt.global_cursor_default=0\"|' /etc/default/grub
    sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=0|' /etc/default/grub
    sed -i 's|^GRUB_TERMINAL=.*|GRUB_TERMINAL=serial|' /etc/default/grub
    grep -q '^GRUB_TERMINAL=' /etc/default/grub || echo 'GRUB_TERMINAL=serial' >> /etc/default/grub
    grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=hidden' >> /etc/default/grub
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin bridge --noclear --noissue --nohints %%I \$TERM\n' \
      > /etc/systemd/system/getty@tty1.service.d/autologin.conf
    touch /home/bridge/.hushlogin && chown bridge:bridge /home/bridge/.hushlogin
    update-grub >/dev/null 2>&1
    systemctl daemon-reload"
  printf '%s\n' "$PROFILE" |
    guest "cat > /home/bridge/.bash_profile && chown bridge:bridge /home/bridge/.bash_profile"
}

stop_qemu() {
  if [ -S "$QMP" ]; then
    hmp quit >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      [ ! -S "$QMP" ] && break
      sleep 0.25
    done
  fi
  if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    die "QEMU still owns $PID; refusing to kill it (stop only this tile safely)"
  fi
  rm -f "$QMP" "$PID"
}

# ALWAYS A COLD BOOT — never -loadvm golden, unlike the production launcher.
# An internal qcow2 snapshot carries the DISK as well as RAM, so restoring the
# golden silently reverts every guest-filesystem change made since the bake.
# That cost a build: this script re-synced /etc/bridge/launch.sh, the next boot
# restored the golden underneath it, and the kiosk came up on the OLD launcher
# with nothing anywhere saying so. A build always boots the live disk.
boot_tile() {
  stop_qemu
  nohup qemu-system-x86_64 \
    -name streamhost-gt40 \
    -enable-kvm -machine pc-i440fx-11.0 \
    -m "$MEM" -smp 2 -cpu host \
    -rtc base=localtime \
    -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
    -vga std \
    -display dbus,p2p=on,audiodev=snd0 \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
    -device AC97,audiodev=snd0 \
    -usb -device usb-tablet \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
    -device e1000,netdev=n0 \
    -qmp unix:"$QMP",server=on,wait=off \
    -pidfile "$PID" \
    >"$TILE_DIR/qemu.log" 2>&1 &
  for _ in $(seq 1 40); do
    [ -S "$QMP" ] && [ -f "$PID" ] && break
    sleep 0.5
  done
  [ -S "$QMP" ] && [ -f "$PID" ] || die "QEMU did not create its QMP socket/pidfile"
  log "QEMU cold-booted from the live overlay (no -loadvm)"
}

capture() {
  local ppm="$EVIDENCE/$1.ppm"
  rm -f "$ppm"
  hmp "screendump $ppm" >/dev/null
  pnmtopng "$ppm" >"$EVIDENCE/$1.png"
  log "framebuffer proof: $EVIDENCE/$1.png"
}

# shellcheck disable=SC2086 # the RECT_* values are deliberate argument tuples
rect() { python3 "$PEN" "$QMP" rect $1; }

# The VT11 is alive when the whole 1024x1024 window carries a real vector
# picture. A bare X root, a dead simulator or a black CRT all measure ~0.
wait_for_vectors() {
  local n
  for _ in $(seq 1 90); do
    n=$(rect "128 0 1024 1024" 2>/dev/null || echo 0)
    [ "$n" -gt 6000 ] && {
      log "VT11 drawing: $n lit pixels"
      return 0
    }
    sleep 2
  done
  die "no VT11 vector picture after 180 seconds"
}

# The menu column must contain all twelve items. vr14, or a root too small for
# the window, clips it mid-word and the count collapses — this is the assertion
# that would have caught the ALTITUD / FUEL LEF geometry bug.
#
# It WAITS rather than sampling once: the tape draws its "introductory message"
# on the very first load and that screen has no menu at all, so a single-shot
# assertion measured 0 there and failed a healthy build. The timeout still makes
# a genuinely clipped menu fail loudly.
wait_for_menu_intact() {
  local n
  for _ in $(seq 1 60); do
    n=$(rect "$RECT_MENU")
    if [ "$n" -gt 5200 ] && [ "$n" -lt 5800 ]; then
      log "telemetry menu column intact ($n lit px, all twelve items)"
      return 0
    fi
    sleep 2
  done
  die "telemetry menu column never measured ~5450 lit px (last $n); geometry is clipping it"
}

# Ride the exhibit's own 135 s loop to a deterministic moment: wait for the
# crash message, then for the restart it triggers. Both edges are asserted, so
# a lander that never crashes (frozen simulator) and one that never restarts
# both fail loudly instead of baking whatever happened to be on the glass.
wait_for_fresh_descent() {
  local n seen=0
  for _ in $(seq 1 150); do
    n=$(rect "$RECT_CRASH")
    [ "$n" -gt 2800 ] && {
      seen=1
      break
    }
    sleep 2
  done
  [ "$seen" -eq 1 ] || die "no crash message in 300 s: the lander is not flying"
  log "crash message on screen; waiting for the program to restart itself"
  # BOTH conditions, every sample. The message is not a steady raster — the
  # VT11's phosphor refresh leaves whole frames blank — so a lone "the crash band
  # went quiet" edge fires MID-MESSAGE (measured: a 0 between two 3104s inside
  # one 12 s message). Requiring the LEM back in its start box in the SAME
  # sample is what actually means "restarted".
  local lem
  for _ in $(seq 1 90); do
    n=$(rect "$RECT_CRASH")
    lem=$(rect "$RECT_LEM")
    if [ "$n" -lt 600 ] && [ "$lem" -gt 1500 ]; then
      log "fresh descent: LEM at 18000 feet in its start box ($lem lit px)"
      return 0
    fi
    sleep 1
  done
  die "no fresh descent within 90 samples of the crash message"
}

bake_golden() {
  if qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
    hmp "delvm golden" >/dev/null
  fi
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

# Blink amplitude of the telemetry menu column, with the pointer PARKED first.
# Parking is not cosmetic: the X core cursor is composited into the captured
# framebuffer, so leaving it in the measured rect adds 19-34 px of noise and
# once masked a real selection. Selected items blink with a LOW duty cycle (2
# dark frames in 20 at 0.15 s), so the window must cross several cycles; an
# 8-sample window missed it outright.
menu_blink() {
  # shellcheck disable=SC2086 # PEN_PARK / RECT_MENU are deliberate tuples
  python3 "$PEN" "$QMP" park $PEN_PARK
  # shellcheck disable=SC2086
  python3 "$PEN" "$QMP" burst 20 0.15 $RECT_MENU | sed 's/.*range=\([0-9]*\).*/\1/'
}

# THE LIGHT PEN PROOF, and it runs only AFTER the bake so nothing it touches can
# reach the golden. lunar.txt: "the user points the light pen at the item he
# wishes to display … the item will then start blinking". That blink IS the
# assertion — the program's own acknowledgement that the pen hit a vector. An
# earlier version asserted only "the framebuffer changed", which a falling
# lander satisfies with no pen at all.
#
# NOT asserted, deliberately: the second half of the gesture (placing the item
# into a readout slot along the top). It works, and was reproduced by hand, but
# it needs the pen to land on a glyph whose x position depends on the current
# digit count and the readouts freeze during the crash message, so a scripted
# hit is not reliable enough to gate a build on. docs/guests/gt40.md says so.
pen_proof() {
  local base sel after
  base=$(menu_blink)
  [ "$base" -lt 80 ] ||
    die "menu column already flickering before the pen touched it (range=$base)"
  # shellcheck disable=SC2086 # PEN_ANGLE is a deliberate x y tuple
  python3 "$PEN" "$QMP" point $PEN_ANGLE 1.2
  capture pen-1-angle-selected
  sel=$(menu_blink)
  [ "$sel" -gt 200 ] ||
    die "light pen on ANGLE did not make it blink (range=$sel vs idle $base)"
  log "light pen proof: ANGLE selected and blinking (range=$sel vs idle $base)"

  # Reset must undo the visitor's selection, not just redraw the picture.
  hmp "loadvm golden" >/dev/null
  sleep 3
  wait_for_vectors
  after=$(menu_blink)
  [ "$after" -lt 80 ] ||
    die "loadvm golden did not clear the pen selection (range=$after)"
  log "reset proof: golden restore cleared the selection (range=$after)"
  capture golden-restored-after-pen
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"
printf '%s\n' "$PEN_PY" >"$PEN"

if [ -f "$OVERLAY" ] && [ "$FORCE" -eq 1 ]; then
  log "--force requested; stopping only $TILE before replacing its overlay"
  stop_qemu
  rm -f "$OVERLAY"
fi
NEW_OVERLAY=0
if [ ! -f "$OVERLAY" ]; then
  log "creating thin overlay on the frozen bridge base"
  qemu-img create -f qcow2 -b "$BRIDGE_BASE" -F qcow2 "$OVERLAY" >/dev/null
  NEW_OVERLAY=1
fi

boot_tile
log "waiting for bridge SSH"
ssh_ready=0
for _ in $(seq 1 40); do
  if guest true 2>/dev/null; then
    ssh_ready=1
    break
  fi
  sleep 3
done
[ "$ssh_ready" -eq 1 ] || die "bridge SSH did not become ready"

if [ "$NEW_OVERLAY" -eq 1 ]; then
  guest "command -v gcc make git >/dev/null && [ -f /usr/include/SDL2/SDL.h ]" ||
    die "the bridge base is missing gcc/make/git/libsdl2-dev; SIMH cannot be built"
  install_simh
fi

# The ini, the launcher and the kiosk profile are re-synced on EVERY run, not
# only when the overlay is new: an edit to any of them is exactly the kind of
# change a re-run is for, and a launcher that only lands on a from-scratch
# rebuild is a trap (a fix "appears not to have taken effect" — AGENTS.md).
printf '%s\n' "$INI" | guest "cat > /opt/bridge/gt40/gt40.ini"
printf '%s\n' "$LAUNCH" |
  guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
    chown root:root /etc/bridge/launch.sh"
quiet_console
guest "for p in \$(pgrep -x pdp11); do kill \$p; done 2>/dev/null || true
  sleep 1
  systemctl reset-failed getty@tty1
  systemctl restart getty@tty1"
sleep 8
wait_for_vectors
capture cold-boot-vectors

# One clean cold boot with the quiet console in force, then ride the program's
# own loop to a fresh descent and bake THAT. Nothing is typed and nothing is
# pointed at before the bake: the mpf2 add shipped a golden carrying its own
# verification output and had to be re-baked.
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
boot_tile
sleep 8
wait_for_vectors
guest "pgrep -x pdp11 >/dev/null" || die "the pdp11 simulator exited after cold boot"
wait_for_menu_intact
guest "XAUTHORITY=/home/bridge/.Xauthority DISPLAY=:0 xwininfo -root -tree |
  grep -q '1024x1024+128+0'" ||
  die "the VT11 window is not 1024x1024+128+0 on the $X_MODE root"
log "VT11 window geometry verified: 1024x1024+128+0 on a $X_MODE root"

wait_for_fresh_descent
# shellcheck disable=SC2086 # PEN_PARK is a deliberate x y tuple
python3 "$PEN" "$QMP" park $PEN_PARK
capture ready-before-golden
bake_golden
sleep 3
wait_for_vectors
capture golden-restored
wait_for_menu_intact

pen_proof

log "PASS: GT40/VT11 Lunar Lander live, light pen proven, fresh-descent golden"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT evidence=$EVIDENCE"
