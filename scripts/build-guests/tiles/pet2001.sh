#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/pet2001.sh — build the Commodore PET 2001 (1977) streamhost tile
# as a thin overlay on the frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-13 (trixie) kiosk running VICE `xpet -model 2001`, emulating
#         the ORIGINAL PET 2001: MOS 6502 at 1 MHz, 8 KB RAM, 40x25 characters
#         of blue-white text on black, no CRTC (the 1977 machine drew its video
#         with discrete logic), chiclet "graphics" keyboard, cassette deck.
#         streamhost captures the Linux framebuffer + AC97 audio exactly like
#         every other bridge tile (streamhost/docs/BRIDGE.md).
# TYPE  : "emulator bridge" tile. Overlay + per-tile /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- WHY THIS TILE IS CHEAP -------------------------------------------------
#   Same argument as vic20.sh/plus4.sh: VICE is already in the frozen bridge
#   base (built from source for the c64 tile; `make install` ships the whole
#   family, so /usr/local/bin/xpet is there) and it BUNDLES the Commodore ROMs.
#   The PET needs nothing else — no tape, no disk, no licensed media. No staged
#   asset, no checksum gate, no check-assets.sh row.
#
# ---- WHICH MODEL, AND WHY ---------------------------------------------------
#   `xpet -help` offers 2001/3008/3016/3032/3032B/4016/4032/4032B/8032/8096/
#   8296/SuperPET. `-model 2001` is the 1977 original, and VICE's own resource
#   dump proves it is the right machine rather than a badge:
#     RamSize=8   Crtc=0   VideoSize=40   KeyboardType=4 (graphics/chiclet)
#     CrtcPaletteFile="2001-blueish.vpl"  (ROM set 1 -> rom1g.vrs)
#   Crtc=0 matters: the 2001 predates the 6545 CRTC that every later PET used.
#   The sibling tile cbm8032 is the OTHER end of the same family (80 columns,
#   business keyboard, BASIC 4) and is deliberately a different exhibit.
#
# ---- WINDOW vs X ROOT (measured here, 2026-08-09) ---------------------------
#   There is no window manager, so an SDL window larger than the X root is
#   silently clipped and mispositioned. Recon had seen a PET clipped at
#   1024x768 — but that was the 80-column 8032. Measured with xwininfo on this
#   overlay, the 40-column 2001 at -CRTCdsize is a 768x532 window:
#     1024x768 root -> window at +128+118, NOT clipped, but only 52% of the
#                      captured frame carries picture;
#     800x600  root -> window at +16+34, still not clipped, 85% of the frame.
#   So the X root drops to 800x600 — the same trick c64/vic20/plus4 use, and
#   for the same reason (VICE's SDL window is fixed and real fullscreen renders
#   BLACK under std-VGA capture; see amstradcpc.sh). Dropping -CRTCdsize
#   instead would halve the picture to 384x266 and is strictly worse.
#
# ---- TRAPS INHERITED FROM THE VIC-20 / PLUS-4 ADDS (both handled below) -----
#   * VICE 3.9 SEGFAULTS whenever its stdout is not a terminal (vice_banner() ->
#     log_helper() -> strlen(NULL)) and prints nothing at all. The kiosk profile
#     therefore leaves stdout on tty1. See docs/guests/vic20.md.
#   * VICE's `make install` SKIPS some ROM data files and the emulator then
#     segfaults on startup with no output. Repair the PET set from the retained
#     source tree and ASSERT it. On this box the PET .bin set happened to be
#     complete already, but the repair + assertion stays: it costs nothing, and
#     the assertion also covers the PALETTE file, which is not a .bin and which
#     model 2001 loads by name (2001-blueish.vpl).
#
# ---- KEY PACING: 80/80, NOT THE 2-FRAME FLOOR -------------------------------
#   SH_KEY_MIN_HOLD_MS=80 / SH_KEY_MIN_GAP_MS=80 — four PAL frames each way.
#   The frame-derived two-frame figure (40/40) is a FLOOR, not an answer: it was
#   bisected on this box for vic20 (scripts/dev/emu-key-pacing-bisect.py) and
#   corrupted 1 line in 22 under host scheduling stalls, while 80/80 lost
#   nothing in 22. Same emulator, same host, so this tile ships 80/80 too — and
#   the type-in proof below is typed at exactly that rate, so the proof
#   exercises the shipped pacing rather than a faster one.
#
# HYGIENE: thin overlay (no full copy), namespaced qmp.sock/pidfile, kills only
# by pidfile, idempotent, --force rebuilds the overlay. Touches ONLY the pet2001
# tile dir; refuses to run while streamhost@pet2001 is active.
#
# Usage: pet2001.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=pet2001
VMID=224
UDP=54088
SSH_PORT=5824
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/pet2001
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
TYPIST="$TILE_DIR/type-paced.py"
# 768 MB: measured on a clone with the kiosk + xpet running, the guest keeps
# MemAvailable ~420 MB, so there is no case for 1024.
MEM=768

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,74p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[pet2001 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[pet2001] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Commodore PET 2001 (1977) ROM BASIC kiosk launcher (bridge tile).
# See scripts/build-guests/tiles/pet2001.sh for the flag rationale. The X root is
# dropped to 800x600 because VICE's SDL window here is a fixed 768x532
# (measured with xwininfo) and there is no window manager to place it.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 800x600 2>/dev/null || true
exec xpet \
  -sounddev alsa \
  -model 2001 \
  -CRTCdsize
EOS

# Kiosk session profile: X with NO core pointer cursor (keyboard-only exhibit),
# console kept quiet. Overlays the bridge base's stock .bash_profile.
#
# DO NOT REDIRECT startx's OUTPUT TO A FILE. VICE 3.9 segfaults at startup with
# no output whenever its stdout is not a terminal; the visible symptom is X
# dying a second after it starts and getty@tty1 looping into start-limit-hit,
# with nothing anywhere naming the emulator (gdb backtrace in
# docs/guests/vic20.md). Leave stdout on tty1, as the stock base profile and
# every other VICE tile do.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (pet2001 overlay). Start X with NO core pointer cursor
# (-nocursor: keyboard-only exhibit). stdout MUST stay on tty1: VICE 3.9
# segfaults in vice_banner() when its stdout is not a terminal.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor
fi
EOS

# The paced typist used by the post-bake proof. It runs on the HOST against this
# tile's QMP socket and sends EXPLICIT press/release pairs at the tile's shipped
# 80 ms hold / 80 ms gap — QEMU's `send-key hold-time` releases asynchronously
# and overlapping calls lose characters on their own (playbook §5.1), and
# `labctl type` bypasses pacing entirely while still printing "ok".
read -r -d '' TYPIST_PY <<'EOS' || true
#!/usr/bin/env python3
"""Type ASCII into the emulated PET over QMP at the tile's shipped pacing.

Letters are sent UNSHIFTED even when the caller passes upper case: on a PET the
unshifted letter keys already produce upper-case glyphs and SHIFT produces the
graphics set, which is exactly what registry `keyboard.letterCase: upper-only`
declares for the SPA typist. Sending Shift+A here would poke a graphics
character into the listing instead of an A.
"""

import json
import os
import socket
import sys
import time

HOLD = float(os.environ.get("PET_HOLD", "0.08"))
GAP = float(os.environ.get("PET_GAP", "0.08"))

UNSHIFTED = {
    " ": "spc", "\n": "ret", "-": "minus", "=": "equal", ";": "semicolon",
    ",": "comma", ".": "dot", "/": "slash", "'": "apostrophe",
    "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
    "`": "grave_accent",
}
for _c in "abcdefghijklmnopqrstuvwxyz0123456789":
    UNSHIFTED[_c] = _c
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal", ":": "semicolon",
    "<": "comma", ">": "dot", "?": "slash", '"': "apostrophe",
    "{": "bracket_left", "}": "bracket_right", "|": "backslash", "~": "grave_accent",
}

qmp_path, text = sys.argv[1], sys.argv[2]
sock = socket.socket(socket.AF_UNIX)
sock.settimeout(180)
sock.connect(qmp_path)
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
        if "error" in msg:
            raise SystemExit("QMP error: %s" % msg)
        if "return" in msg:
            return msg


cmd("qmp_capabilities")


def key(qcode, down):
    cmd(
        "input-send-event",
        events=[{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}],
    )


def tap(qcode, shift=False):
    if shift:
        key("shift", True)
        time.sleep(HOLD)
    key(qcode, True)
    time.sleep(HOLD)
    key(qcode, False)
    time.sleep(GAP)
    if shift:
        key("shift", False)
        time.sleep(GAP)


for ch in text:
    low = ch.lower()
    if low in UNSHIFTED:
        tap(UNSHIFTED[low])
    elif ch in SHIFTED:
        tap(SHIFTED[ch], shift=True)
    else:
        raise SystemExit("unmapped character %r" % ch)
EOS

# VICE's `make install` skips ROM data files and the emulator then segfaults on
# startup with NO output (it bit c64 on the C64 BASIC ROM and vic20 on
# basic-901486-01.bin). Repair from the source tree the base retains, and assert
# the four files `-model 2001` actually loads — rom1g.vrs names them — plus the
# external palette the model selects, which is not a .bin and would be missed by
# a *.bin-only copy.
repair_pet_roms() {
  # shellcheck disable=SC2016 # $src/$r are the GUEST shell's variables, by design
  guest 'set -e
    src=/usr/local/src/vice-3.9/data/PET
    [ -d "$src" ] || { echo "VICE source data tree missing: $src" >&2; exit 1; }
    install -d -m 755 /usr/local/share/vice/PET
    cp -n "$src"/*.bin "$src"/*.vpl "$src"/*.vrs /usr/local/share/vice/PET/ 2>/dev/null || true
    for r in basic-1.901439-09-05-02-06.bin kernal-1.901439-04-07.bin \
             edit-1-n.901439-03.bin characters-1.901447-08.bin \
             rom1g.vrs 2001-blueish.vpl; do
      [ -s "/usr/local/share/vice/PET/$r" ] || { echo "missing PET data file: $r" >&2; exit 1; }
    done' ||
    die "could not complete the PET ROM set in the guest (BASIC 1 / KERNAL 1 / editor / chargen / palette)"
  log "PET ROM set complete (BASIC 1 + KERNAL 1 + editor + chargen + 2001 palette)"
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

boot_tile() {
  stop_qemu
  local LOADVM=""
  qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
  # shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish)
  nohup qemu-system-x86_64 \
    -name streamhost-pet2001 \
    -enable-kvm -machine pc-i440fx-11.0,vmport=off \
    -m "$MEM" -smp 2 -cpu host \
    -rtc base=localtime \
    -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
    -vga std \
    -display dbus,p2p=on,audiodev=snd0 \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
    -device AC97,audiodev=snd0 \
    -usb \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
    -device e1000,netdev=n0 \
    $LOADVM \
    -qmp unix:"$QMP",server=on,wait=off \
    -pidfile "$PID" \
    >"$TILE_DIR/qemu.log" 2>&1 &
  for _ in $(seq 1 40); do
    [ -S "$QMP" ] && [ -f "$PID" ] && break
    sleep 0.5
  done
  [ -S "$QMP" ] && [ -f "$PID" ] || die "QEMU did not create its QMP socket/pidfile"
  log "QEMU started (loadvm='${LOADVM:-<none: cold boot>}')"
}

capture() {
  local name=$1
  local ppm="$EVIDENCE/$name.ppm"
  rm -f "$ppm"
  hmp "screendump $ppm" >/dev/null
  pnmtopng "$ppm" >"$EVIDENCE/$name.png"
  log "framebuffer proof: $EVIDENCE/$name.png"
}

# Count lit phosphor. Unlike the VIC-20 and the Plus/4, which paint a bright
# PAPER, the PET draws a handful of blue-white glyphs on black — so the metric
# is small and precise rather than large and coarse.
lit() {
  ppmhist "$EVIDENCE/$1.ppm" 2>/dev/null |
    awk '$1 > 96 && $2 > 96 && $3 > 96 { sum += $5 } END { print sum + 0 }'
}

# READY predicate: the untouched power-on screen and NOTHING ELSE.
#
# TWO conditions, because the lit-pixel count ALONE is not enough — this was not
# a theory, the first run of this builder tripped over it. Measured at 800x600:
# the three-line banner is 1600 lit pixels, the block cursor adds 256 in its on
# phase, a listed program is 6318 and the running demo 19360. But GRUB's
# "Booting `Debian GNU/Linux'" text screen, four seconds into a cold boot,
# measures 2067 — inside the band — and the first run baked its golden pointed
# at THAT. What separates them is the geometry: VGA text mode is 720x400, the
# kiosk's X root is 800x600, so requiring the exact captured size rejects every
# console/GRUB frame outright. A bare X root, a dead xpet or a kiosk that never
# started X are 800x600 with 0 lit pixels and fail on the band.
#
# The band's UPPER bound is what makes this able to fail on a dirty screen; the
# geometry is what makes it able to fail on a screen that is not the PET at all.
PET_LIT_MIN=${PET_LIT_MIN:-1200}
PET_LIT_MAX=${PET_LIT_MAX:-4000}
PET_GEOMETRY=${PET_GEOMETRY:-800 600}
wait_for_pet_ready() {
  local name=$1 n geom
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      geom=$(head -c 32 "$EVIDENCE/$name.ppm" | tr '\n' ' ' | awk '{print $2, $3}')
      n=$(lit "$name")
      if [ "$geom" = "$PET_GEOMETRY" ] &&
        [ "$n" -ge "$PET_LIT_MIN" ] && [ "$n" -le "$PET_LIT_MAX" ]; then
        log "PET ready screen (${geom// /x}, lit=$n, band $PET_LIT_MIN..$PET_LIT_MAX)"
        return 0
      fi
    fi
    sleep 2
  done
  die "no untouched PET BASIC screen after 180 s (last ${geom:-?}, lit=${n:-none})"
}

wait_for_ssh() {
  for _ in $(seq 1 40); do
    guest true 2>/dev/null && return 0
    sleep 3
  done
  die "bridge SSH did not become ready on 127.0.0.1:$SSH_PORT"
}

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

# The type-in the exhibit advertises (registry spa.demoProgram), typed at the
# SHIPPED 80/80 pacing against the RESTORED fixture, so nothing it types can
# ever reach the golden. Two framebuffer assertions, both able to fail:
#   1. after LIST, the screen must carry a listing — far more lit phosphor than
#      the banner, but far less than a running plot;
#   2. after RUN, the screen must fill with plotted characters.
# An assertion of the form "the framebuffer changed" would pass on a single
# stray character, which is exactly the failure this is meant to catch.
demo_proof() {
  local n
  # shellcheck disable=SC2016 # chr$( is PET BASIC, not a host expansion
  python3 "$TYPIST" "$QMP" '10 print chr$(147)
20 x=int(rnd(1)*1000)
30 poke 32768+x,81
40 goto 20
list
'
  sleep 2
  capture keyboard-1-listing
  n=$(lit keyboard-1-listing)
  [ "$n" -gt 4500 ] ||
    die "the type-in did not reach BASIC (lit=$n; expected a listing, ~6300)"
  log "demo proof 1/2: program typed and LISTed (lit=$n)"

  python3 "$TYPIST" "$QMP" 'run
'
  local ok=0
  for _ in $(seq 1 15); do
    sleep 2
    capture keyboard-2-running
    n=$(lit keyboard-2-running)
    [ "$n" -gt 9000 ] && {
      ok=1
      break
    }
  done
  [ "$ok" -eq 1 ] ||
    die "RUN did not plot into screen memory (lit=$n; expected >9000)"
  log "demo proof 2/2: RUN plots into PET screen RAM at 32768 (lit=$n)"

  hmp "loadvm golden" >/dev/null
  sleep 3
  wait_for_pet_ready golden-restored-after-keyboard
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"
printf '%s\n' "$TYPIST_PY" >"$TYPIST"

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

if [ "$NEW_OVERLAY" -eq 1 ]; then
  boot_tile
  log "waiting for bridge SSH"
  wait_for_ssh
  guest "command -v xpet >/dev/null" ||
    die "xpet missing from the bridge base (rebuild it with bridge-base.sh)"
  repair_pet_roms
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  guest "pkill -u bridge xpet 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  sleep 8
  wait_for_pet_ready cold-boot-basic
fi

# One clean cold boot with the quiet console in force, then bake the golden from
# the very state SPA reset restores for ever after. THE FIXTURE IS THE UNTOUCHED
# POWER-ON SCREEN — the state the machine itself chose. Nothing is typed before
# the bake (mpf2 shipped a golden carrying its own verification output and had
# to be re-baked; plus4 shipped one curated deep inside an application and was
# rejected on the exhibit floor).
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
boot_tile
wait_for_ssh
wait_for_pet_ready ready-before-golden
guest "pgrep -x xpet >/dev/null" || die "xpet exited after cold boot"
bake_golden
sleep 3
wait_for_pet_ready golden-restored

demo_proof

log "PASS: PET 2001 power-on fixture, type-in demo proven, quiet console, golden"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT evidence=$EVIDENCE"
