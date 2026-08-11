#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/cbm8032.sh — build the Commodore CBM 8032 (1980) streamhost station
# as a thin overlay on the frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-13 (trixie) kiosk running VICE `xpet -model 8032`, emulating
#         the 80-column business PET, which boots its ROM straight to
#         "*** commodore basic 4.0 ***" in green on black.
# TYPE  : "emulator bridge" station. Overlay + per-station /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- WHY THIS TILE IS CHEAP -------------------------------------------------
#   Same argument as vic20.sh and plus4.sh: VICE is ALREADY in the frozen bridge
#   base (built from source for the c64 station; `make install` ships the whole
#   family, xpet included) and it BUNDLES the Commodore ROMs. A CBM 8032 needs
#   no disk, no cartridge and no tape to reach BASIC, so the exhibit is the ROM
#   and the ROM is already there: no staged asset, no checksum gate, no
#   check-assets.sh row.
#
# ---- THE EXHIBIT ------------------------------------------------------------
#   CBM 8032 (1980): MOS 6502 at 1 MHz, 32 KB RAM (31743 BASIC bytes free),
#   80x25 characters of green text on a 12-inch integrated monitor, BASIC 4.0
#   with its disk commands, a business keyboard, and NO colour, NO sprites and
#   NO sound generator at all. It is the most "office computer" machine
#   Commodore ever made, and the starkest exhibit in the 8-bit row: everything
#   its home-computer siblings are remembered for is missing.
#
#   THE GOLDEN IS THE MACHINE'S OWN UNTOUCHED POWER-ON SCREEN. Nothing is typed
#   into it. (The Plus/4 add shipped a golden curated deep inside an application
#   and had to be re-baked: a visitor arrived in the middle of a program with no
#   idea what it was or how to leave. Bake the state the machine itself chose,
#   and put the affordances in the UI around it.) The exhibit's interaction is
#   the registry `demoProgram` — a BASIC 4.0 times table that fills all 80
#   columns — which this builder types and RUNS after the bake, so what ships is
#   what was proven.
#
# ---- WINDOW GEOMETRY: MEASURED, NOT GUESSED ---------------------------------
#   There is no window manager in the kiosk, so an SDL window larger than the X
#   root is silently CLIPPED and mispositioned — recon's first attempt at this
#   machine left only the tail of "ytes free" visible on a 1024x768 root and
#   nothing anywhere said why. Measured here on a soltest clone by painting the
#   X root navy and taking the bounding box of everything that was not navy:
#
#     flags          window       fits 1024x768?  fits 1600x1200?  fits 1920x1080?
#     (none)          704 x  532   yes             yes              yes
#     -CRTCdsize     1408 x 1064   NO (1064>768)   yes (96/68 slack) yes (256/8 slack)
#
#   1600x1200 is what ships. It is the tightest advertised mode that contains
#   the doubled window (78% of the captured frame is the emulated screen, vs 72%
#   at 1920x1080), it costs fewer scanout pixels, and its 4:3 shape is the shape
#   of the machine's own 12-inch monitor. Undoubled would fit a 1024x768 root but
#   throws away half the resolution of an 80-column screen, which is the one
#   thing this exhibit is about.
#
#   NOTE there is no `-CRTCborders` — unlike VIC-II/TED/VIC, VICE's CRTC video
#   chip has no border resource, so the border (64 px each side horizontally and
#   82 vertically at -CRTCdsize, around a 1280x900 text area) is not removable
#   and the sibling stations' `-XXXborders 0` has no counterpart here. Asking for it
#   is not merely ignored: xpet prints "Unknown option '-CRTCborders'. Error
#   parsing command-line options, bailing out." and exits, taking X with it.
#
# ---- TWO TRAPS INHERITED FROM THE VIC-20 / PLUS-4 ADDS (both handled below) --
#   * VICE 3.9 SEGFAULTS whenever its stdout is not a terminal (vice_banner() ->
#     strlen(NULL)) and prints nothing at all; the visible symptom is X dying a
#     second after it starts and getty@tty1 looping into start-limit-hit, with
#     nothing in any log naming the emulator. The kiosk profile therefore leaves
#     stdout on tty1 and NEVER redirects startx to a file. See docs/guests/vic20.md.
#   * VICE's `make install` SKIPS ROM data files, and the emulator then segfaults
#     on startup with no output (it bit the C64 on its BASIC ROM and the VIC-20
#     on basic-901486-01.bin). Repair the PET set from the source tree the base
#     retains and ASSERT the four ROMs a `-model 8032` actually loads, rather
#     than trusting the copy.
#
# ---- A THIRD TRAP, NEW HERE: THE READY SCREEN IS THE *SPARSE* ONE -----------
#   The PET's screen RAM is uninitialised at power-on, so for the first moments
#   after xpet starts the CRTC paints all 2000 cells of random bytes as random
#   glyphs — a solid green block. A "there is green on the screen" readiness
#   predicate accepts that garbage frame (measured: 375726 green pixels against
#   the banner's 1597) and would happily bake it as the golden. wait_for_basic()
#   below therefore tests a BAND, not a floor: real PET text is sparse.
#
# HYGIENE: thin overlay (no full copy), namespaced qmp.sock/pidfile, kills only
# by pidfile, idempotent, --force rebuilds the overlay. Touches ONLY the cbm8032
# station dir; refuses to run while streamhost@cbm8032 is active.
#
# Usage: cbm8032.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=cbm8032
VMID=225
UDP=54109
SSH_PORT=5825
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/stations/cbm8032
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
DEMO_DRIVER="$TILE_DIR/demo-drive.py"
# 768 MB, not the 1536 the other kiosks carry. Measured in the guest with
# xpet up at 1600x1200: MemAvailable 397736 kB, i.e. 388 MB still free, so the
# station costs labhost half of what its siblings do. assert_memory() below keeps
# that honest on every build.
MEM=768
ROOT_W=1600
ROOT_H=1200

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,86p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[cbm8032 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[cbm8032] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# VICE's SDL window is a fixed size and cannot grow (real fullscreen renders
# BLACK under std-VGA capture — see amstradcpc.sh), so the X root is sized to
# CONTAIN it instead. 1600x1200 for the 1408x1064 doubled window; see the
# measurement table in the header for why not 1024x768 or 1920x1080.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Commodore CBM 8032 (1980) ROM BASIC 4.0 kiosk launcher (kiosk).
# See scripts/build-guests/tiles/cbm8032.sh for the flag rationale.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 1600x1200 2>/dev/null || true
exec xpet \
  -model 8032 \
  -sounddev alsa \
  -CRTCdsize
EOS

# Kiosk session profile: X with NO core pointer cursor (keyboard-only exhibit —
# the core pointer would otherwise sit frozen mid-screen), console kept quiet.
#
# DO NOT REDIRECT startx's OUTPUT TO A FILE. VICE 3.9 segfaults at startup
# whenever its stdout is not a terminal, before it prints a single byte
# (vice_banner() -> log_message(" ") -> strlen(NULL); gdb backtrace in
# docs/guests/vic20.md). Leaving stdout on tty1 is exactly why the stock base
# profile and the c64/vic20/plus4 stations work.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (cbm8032 overlay). Start X with NO core pointer cursor
# (-nocursor: keyboard-only exhibit). stdout MUST stay on tty1: VICE 3.9
# segfaults in vice_banner() when its stdout is not a terminal.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor
fi
EOS

# The demo driver: types the REGISTRY listing (registry/stations/cbm8032.json
# spa/demoProgram) into the emulated PET over this station's QMP socket, at the
# station's production key pacing. Runs on the HOST; the guest has no idea.
read -r -d '' DEMO_PY <<'EOS' || true
#!/usr/bin/env python3
"""Type the cbm8032 registry demo listing into the emulated PET over QMP.

Paced at 80 ms hold / 80 ms gap — the SAME numbers the tile ships as
SH_KEY_MIN_HOLD_MS / SH_KEY_MIN_GAP_MS — so this proof exercises what the SPA
typist actually gets through streamhost, not a faster path that would pass
where the exhibit fails.

KEEP THE `LINES` LIST AND THE REGISTRY `demoProgram.lines` IDENTICAL. The
registry entry is what the SPA types; this is what the build proves.
"""

import json
import socket
import sys
import time

HOLD = GAP = 0.080

# US-layout host key for each character the listing needs. VICE's PET business
# keymap (sdl_buuk_sym.vkm) maps host ASCII straight onto the 8032 matrix, so
# no per-machine charMap is needed — verified by framebuffer, every character
# of the listing below arrives as itself.
PLAIN = {" ": "spc", "\n": "ret", "-": "minus", "=": "equal", ";": "semicolon",
         ",": "comma", ".": "dot", "/": "slash", "'": "apostrophe"}
SHIFTED = {"$": "4", "(": "9", ")": "0", "*": "8", ":": "semicolon",
           '"': "apostrophe", "+": "equal", "#": "3", "?": "slash"}

LINES = [
    "10 print chr$(147)",
    "20 for r=1 to 12",
    "30 for c=1 to 8",
    "40 print tab((c-1)*10);r*c;",
    "50 next c:print:next r",
]
RUN = "run"


def qcode(ch):
    if ch in PLAIN:
        return None, PLAIN[ch]
    if ch in SHIFTED:
        return "shift", SHIFTED[ch]
    if ch.isdigit() or "a" <= ch <= "z":
        return None, ch
    if "A" <= ch <= "Z":
        return "shift", ch.lower()
    raise SystemExit("no qcode for %r" % ch)


class QMP:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(120)
        self.sock.connect(path)
        self.conn = self.sock.makefile("rwb")
        self.conn.readline()
        self.cmd("qmp_capabilities")

    def cmd(self, execute, **args):
        payload = {"execute": execute}
        if args:
            payload["arguments"] = args
        self.conn.write((json.dumps(payload) + "\n").encode())
        self.conn.flush()
        while True:
            msg = json.loads(self.conn.readline())
            if "error" in msg:
                raise SystemExit(msg["error"])
            if "return" in msg:
                return msg

    def key(self, code, down):
        self.cmd("input-send-event", events=[
            {"type": "key",
             "data": {"down": down, "key": {"type": "qcode", "data": code}}}])

    def tap(self, ch):
        mod, code = qcode(ch)
        if mod:
            self.key(mod, True)
            time.sleep(HOLD)
        self.key(code, True)
        time.sleep(HOLD)
        self.key(code, False)
        if mod:
            self.key(mod, False)
        time.sleep(GAP)

    def line(self, text):
        for ch in text:
            self.tap(ch)
        self.tap("\n")
        # BASIC tokenises the line it just received; while it does, its keyboard
        # buffer can miss the next character (the same settle the UI typist
        # applies as DEMO_ENTER_DELAY_MS).
        time.sleep(0.6)


qmp = QMP(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else "--all"

if mode in ("--all", "--listing"):
    for listing_line in LINES:
        qmp.line(listing_line)
    print("listing typed")

if mode in ("--all", "--run"):
    qmp.line(RUN)
    time.sleep(4)
    print("run")
EOS

# The four ROMs `xpet -model 8032` loads, from src/pet/petmodel.c (RAM_32K,
# COLS_80, KBD_TYPE_BUSINESS_UK) resolved through src/pet/petrom.h:
#   basic-4.901465-23-20-21.bin      BASIC 4.0
#   kernal-4.901465-22.bin           KERNAL 4
#   edit-4-80-b-50Hz.901474-04_.bin  80-column business editor, 50 Hz
#   characters-2.901447-10.bin       character generator
# Assert the BASENAMES, not "the copy succeeded" — the `make install` gap this
# guards against leaves a tree that looks populated and is missing one file.
repair_pet_roms() {
  # shellcheck disable=SC2016 # $src/$r are the GUEST shell's variables, by design
  guest 'set -e
    src=/usr/local/src/vice-3.9/data/PET
    [ -d "$src" ] || { echo "VICE source data tree missing: $src" >&2; exit 1; }
    install -d -m 755 /usr/local/share/vice/PET
    cp -n "$src"/*.bin /usr/local/share/vice/PET/ 2>/dev/null || true
    cp -n "$src"/*.vpl "$src"/*.vrs /usr/local/share/vice/PET/ 2>/dev/null || true
    for r in basic-4.901465-23-20-21.bin kernal-4.901465-22.bin \
             edit-4-80-b-50Hz.901474-04_.bin characters-2.901447-10.bin; do
      [ -s "/usr/local/share/vice/PET/$r" ] || { echo "missing PET ROM: $r" >&2; exit 1; }
    done' ||
    die "could not complete the PET ROM set in the guest (BASIC 4 / KERNAL 4 / 80-col editor / chargen)"
  log "PET ROM set complete (BASIC 4.0 + KERNAL 4 + 80-column business editor + chargen)"
}

# Quiet every text-producing stage of a cold boot (GRUB -> kernel -> agetty).
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
    -name streamhost-cbm8032 \
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

# Green phosphor pixels in a capture. The whole exhibit is green-on-black —
# there is no bright "paper" to count as there is on the VIC-20 or Plus/4 — so
# the readiness predicate counts pixels whose green channel dominates. A bare X
# root, or a dead xpet, scores 0.
green_of() {
  ppmhist "$EVIDENCE/$1.ppm" 2>/dev/null |
    awk '$2 > 90 && $1 < $2 / 2 && $3 < $2 / 2 { sum += $5 } END { print sum + 0 }'
}

# The QEMU scanout IS the X root, so the capture's own PPM header proves the
# xrandr mode actually took. An unresized 1024x768 root would clip the 1064-tall
# window and is the single most likely way this station ships broken.
assert_root_size() {
  local got
  got=$(head -2 "$EVIDENCE/$1.ppm" | tail -1)
  [ "$got" = "$ROOT_W $ROOT_H" ] ||
    die "X root is '$got', expected '$ROOT_W $ROOT_H' — the 1408x1064 window would be clipped"
}

# The BASIC 4.0 banner is three short lines plus a blinking cursor: 1597 green
# pixels with the cursor off, 1985 with it on, measured on a clone AND on this
# station. A black root or a dead xpet scores 0.
#
# THE CEILING IS NOT DECORATION. A floor alone passes on the WRONG SCREEN: the
# PET's screen RAM is uninitialised at power-on, so for the first moments after
# xpet starts the CRTC paints all 2000 cells of random bytes as random glyphs —
# a solid green block of garbage. The first version of this predicate accepted
# it at green=375726 and called it "BASIC 4.0 screen present". Real text is
# SPARSE; 20000 is an order of magnitude above the busiest legitimate screen
# this station ever shows (the RUN table, 6954) and an order of magnitude below the
# garbage.
CBM8032_MIN_GREEN=${CBM8032_MIN_GREEN:-1200}
CBM8032_MAX_GREEN=${CBM8032_MAX_GREEN:-20000}
wait_for_basic() {
  local name=$1 green
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      green=$(green_of "$name")
      if [ "$green" -gt "$CBM8032_MIN_GREEN" ] && [ "$green" -lt "$CBM8032_MAX_GREEN" ]; then
        assert_root_size "$name"
        log "BASIC 4.0 screen present (green=$green, root ${ROOT_W}x${ROOT_H})"
        return 0
      fi
    fi
    sleep 2
  done
  die "no CBM 8032 BASIC 4.0 framebuffer after 180 seconds"
}

# The station runs on 768 MB. Prove there is real headroom left INSIDE the guest
# with the emulator up, rather than assuming it — this is the number that would
# have to move the station to 1024.
assert_memory() {
  local avail
  avail=$(guest "awk '/MemAvailable/ {print \$2}' /proc/meminfo") ||
    die "could not read /proc/meminfo in the guest"
  [ "$avail" -gt 200000 ] ||
    die "guest MemAvailable is ${avail} kB with xpet up; raise MEM above ${MEM}"
  log "guest MemAvailable ${avail} kB with xpet running (floor 200000)"
}

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

# Keyboard proof, run AFTER the bake against the RESTORED fixture so nothing it
# types can ever reach the golden. It types the exhibit's REGISTERED listing and
# runs it, and asserts each step by what is on the screen:
#   * the listing adds five lines of text to a three-line banner  -> green roughly doubles
#   * RUN clears the screen and paints a 12x8 table across all 80 columns
#     -> green roughly doubles again (measured: 1985 idle, 3861 listed, 7342 run)
# An earlier version of this proof asserted only "the framebuffer changed",
# which would have passed on a single stray character. A proof that cannot fail
# is not a proof.
keyboard_proof() {
  local green
  python3 "$DEMO_DRIVER" "$QMP" --listing
  sleep 2
  capture keyboard-1-listing
  green=$(green_of keyboard-1-listing)
  [ "$green" -gt 3000 ] ||
    die "the demo listing did not reach BASIC (green=$green, expected >3000)"
  log "keyboard proof 1/2: the five-line listing is on screen (green=$green)"

  python3 "$DEMO_DRIVER" "$QMP" --run
  sleep 3
  capture keyboard-2-run
  green=$(green_of keyboard-2-run)
  [ "$green" -gt 6000 ] ||
    die "RUN did not paint the 80-column table (green=$green, expected >6000)"
  log "keyboard proof 2/2: RUN filled all 80 columns (green=$green)"

  hmp "loadvm golden" >/dev/null
  sleep 3
  wait_for_basic golden-restored-after-keyboard
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"
printf '%s\n' "$DEMO_PY" >"$DEMO_DRIVER"

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
  ssh_ready=0
  for _ in $(seq 1 40); do
    if guest true 2>/dev/null; then
      ssh_ready=1
      break
    fi
    sleep 3
  done
  [ "$ssh_ready" -eq 1 ] || die "bridge SSH did not become ready"
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
  sleep 6
  wait_for_basic cold-boot-basic
fi

# One clean cold boot with the quiet console in force, then bake the golden from
# the very state UI reset will restore for ever after. Bake from an UNTOUCHED
# cold boot: the mpf2 add shipped a golden carrying its own verification output
# and had to be re-baked.
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
boot_tile
sleep 6
wait_for_basic ready-before-golden
guest "pgrep -x xpet >/dev/null" || die "xpet exited after cold boot"
assert_memory
bake_golden
sleep 3
wait_for_basic golden-restored

keyboard_proof

log "PASS: CBM 8032 BASIC 4.0 fixture, demo listing proven, quiet console, golden"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT mem=${MEM}M evidence=$EVIDENCE"
