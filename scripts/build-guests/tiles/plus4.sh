#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/plus4.sh — build the Commodore Plus/4 (1984) streamhost tile as a
# thin overlay on the frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk running VICE `xplus4` emulating a PAL
#         Commodore Plus/4, curated into its built-in ROM office suite.
# TYPE  : "emulator bridge" tile. Overlay + per-tile /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- WHY THIS TILE IS CHEAP -------------------------------------------------
#   Same argument as vic20.sh: VICE is already in the frozen bridge base and
#   bundles the Commodore ROMs. For the Plus/4 that includes 3plus1-317053-01
#   and 3plus1-317054-01 — the "3-plus-1" office suite itself — so the exhibit's
#   whole point needs NO external media, no licensed image and no asset row.
#
# ---- THE EXHIBIT: THE ROM SOFTWARE, WITH ITS CHOOSER ALREADY OPEN -----------
#   The Plus/4 is remembered as Commodore's misfire, but the reason it exists is
#   the four applications burned into its ROM: word processor, spreadsheet,
#   database and graphing, available a second after power-on with no disk.
#
#   The machine advertises them itself — its power-on screen reads
#   "COMMODORE BASIC V3.5 / 3-PLUS-1 ON KEY F1" — and the suite carries its own
#   module chooser. All of this is the machine's own UI, verified on a clone by
#   framebuffer (2026-08-08):
#
#     power-on  ->  F1 then RETURN        (the ROM's own hint; = SYS 1525)
#     in suite  ->  C= + C                opens the command prompt "W>"/"C>"
#     at prompt ->  tc RETURN  spreadsheet ("to Calculator")
#                   tf RETURN  database    ("to File manager")
#                   tw RETURN  word processor
#
#   THE PROMPT IS ONE-SHOT. C= + C opens it, ONE command runs, and it closes
#   again — measured on a clone, not assumed: typing tw at the "C>" the
#   spreadsheet shows after a tc does not switch module, it enters 0 into cell
#   R1C1, because that line is the cell editor and not a live chooser. So there
#   is no persistent chooser state to bake into, and every module switch needs
#   the Commodore key.
#
#   THE GOLDEN IS THE MACHINE'S OWN POWER-ON SCREEN, nothing curated. An earlier
#   version baked inside the suite, resting in the spreadsheet, and it was wrong
#   on the exhibit floor: a visitor arrived in the middle of one application,
#   with no idea what it was, how it got there or how to leave. The power-on
#   screen is both the machine's honest empty state AND its own launcher — the
#   ROM prints "3-PLUS-1 ON KEY F1", which tells the visitor exactly what to do
#   next. Nothing the gallery could invent says it better.
#
#   The choice of application is then made OUTSIDE the guest, because the C= key
#   a module switch needs does not exist on a Mac, a PC or a phone (it is Tab
#   under VICE's symbolic keymap, which nobody would guess). The SPA's plus4
#   on-screen keyboard carries a 3-PLUS-1 button (F1, RETURN — what the screen
#   asks for) and then one-tap Word / Calc / File buttons, each sending
#   C=(hold) c, then tw / tc / tf, then RETURN as a single macro.
#
#   KNOWN COSMETIC ARTEFACT: under VICE's symbolic keymap, C= + C *also*
#   delivers a literal "c" — measured 0 clean chords out of 11 across 0.30 s and
#   0.50 s modifier leads on an empty document, so it is inherent to the keymap
#   and not a pacing bug (the positional keymap does not leak, but there Tab is
#   not C= at all and the prompt never opens). In the word processor that "c"
#   lands in the document; in the spreadsheet it lands in the cell line and is
#   discarded with the command.
#
# ---- TWO TRAPS INHERITED FROM THE VIC-20 ADD (both handled below) -----------
#   * VICE 3.9 SEGFAULTS whenever its stdout is not a terminal (vice_banner() ->
#     strlen(NULL)) and prints nothing at all. The kiosk profile therefore
#     leaves stdout on tty1. See docs/guests/vic20.md.
#   * VICE's `make install` SKIPS ROM data files; the emulator then segfaults on
#     startup with no output. Repair the PLUS4 set from the retained source tree
#     and ASSERT it, rather than trusting the copy.
#
# ---- A THIRD TRAP, NEW HERE: A CHORD IS NOT A KEY ---------------------------
#   The obvious diagnosis for the stray "c" above is the pacing lesson applied
#   to a chord — that the matrix is scanned once per frame, so the letter is
#   sampled before the modifier is established. It is worth writing down that
#   this diagnosis is WRONG here: leads of 0.30 s and 0.50 s (15 and 25 PAL
#   frames) on an empty document were 0/11 clean, i.e. no better than pressing
#   both at once. VICE's symbolic keymap delivers the letter as well as the
#   combination, and no host-side timing changes that. Measure before believing
#   a mechanism that has worked before.
#
# HYGIENE: thin overlay, namespaced qmp.sock/pidfile, kills only by pidfile,
# idempotent, --force rebuilds. Touches ONLY the plus4 tile dir; refuses to run
# while streamhost@plus4 is active.
#
# Usage: plus4.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=plus4
VMID=222
UDP=54086
SSH_PORT=5822
WEB_PORT=8122
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/plus4
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
FIXTURE_DRIVER="$TILE_DIR/fixture-drive.py"
MEM=1536

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,60p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[plus4 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[plus4] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# VICE's SDL window is fixed and cannot grow (real fullscreen renders BLACK
# under std-VGA capture — see amstradcpc.sh), so the X root drops to the
# smallest advertised mode that contains it, exactly as c64/vic20 do. At
# -TEDdsize the Plus/4's doubled PAL frame fills 800x600 edge to edge.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Commodore Plus/4 (PAL) ROM-software kiosk launcher (bridge tile).
# See scripts/build-guests/tiles/plus4.sh for the flag rationale.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 800x600 2>/dev/null || true
exec xplus4 \
  -sounddev alsa \
  -TEDdsize \
  -TEDborders 0 \
  -pal
EOS

# Kiosk session profile. DO NOT REDIRECT startx's OUTPUT TO A FILE: VICE 3.9
# segfaults at startup whenever its stdout is not a terminal, before it prints
# anything (docs/guests/vic20.md has the gdb backtrace). The visible symptom is
# X dying a second after it starts and getty@tty1 looping to start-limit-hit,
# with nothing in any log naming the emulator.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (plus4 overlay). Start X with NO core pointer cursor
# (-nocursor: keyboard-only exhibit). stdout MUST stay on tty1: VICE 3.9
# segfaults in vice_banner() when its stdout is not a terminal.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor
fi
EOS

# The fixture driver: cold BASIC prompt -> 3-plus-1 -> chooser -> spreadsheet.
# Runs on the HOST against this tile's QMP socket (the guest has no idea).
read -r -d '' FIXTURE_PY <<'EOS' || true
#!/usr/bin/env python3
"""Drive the emulated Plus/4 from its BASIC prompt into the golden fixture.

Sequence, all of it the machine's own UI:
  F1, RETURN            -> the ROM's advertised "3-PLUS-1 ON KEY F1" (SYS 1525)
  C= (held) + C         -> the suite's command prompt
  tc, RETURN            -> the spreadsheet, prompt still open as "C>"
"""

import json
import socket
import sys
import time

QMP = sys.argv[1]
HOLD, GAP = 0.12, 0.12

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


def key(qcode, down):
    cmd(
        "input-send-event",
        events=[{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}],
    )


def tap(qcode):
    key(qcode, True)
    time.sleep(HOLD)
    key(qcode, False)
    time.sleep(GAP)


def chord(modifier, qcode):
    """The modifier is established well before the letter. That does NOT stop
    VICE's symbolic keymap from also delivering the letter to the document (0
    clean chords in 11 trials at 0.30 s and 0.50 s leads) — the lead is kept
    because it costs nothing and the opposite order is certainly wrong."""
    key(modifier, True)
    time.sleep(0.30)
    key(qcode, True)
    time.sleep(HOLD)
    key(qcode, False)
    time.sleep(HOLD)
    key(modifier, False)
    time.sleep(GAP)


mode = sys.argv[2] if len(sys.argv) > 2 else "--all"

if mode in ("--all", "--suite-only"):
    tap("f1")  # the ROM's own hint: "3-PLUS-1 ON KEY F1"
    time.sleep(0.6)
    tap("ret")
    time.sleep(6)
    print("3-plus-1 entered (word processor)")

if mode in ("--all", "--calc-only"):
    chord("tab", "c")  # C= is Tab under VICE's symbolic keymap
    time.sleep(2.5)
    for qcode in ("t", "c", "ret"):  # "to Calculator"
        tap(qcode)
    time.sleep(3)
    print("switched to the spreadsheet")
EOS

repair_plus4_roms() {
  # shellcheck disable=SC2016 # $src/$r are the GUEST shell's variables, by design
  guest 'set -e
    src=/usr/local/src/vice-3.9/data/PLUS4
    [ -d "$src" ] || { echo "VICE source data tree missing: $src" >&2; exit 1; }
    install -d -m 755 /usr/local/share/vice/PLUS4
    cp -n "$src"/*.bin /usr/local/share/vice/PLUS4/ 2>/dev/null || true
    for r in basic-318006-01.bin kernal-318005-05.bin 3plus1-317053-01.bin 3plus1-317054-01.bin; do
      [ -s "/usr/local/share/vice/PLUS4/$r" ] || { echo "missing PLUS4 ROM: $r" >&2; exit 1; }
    done' ||
    die "could not complete the PLUS4 ROM set in the guest (BASIC/KERNAL/3-plus-1)"
  log "PLUS4 ROM set complete (BASIC + KERNAL + both 3-plus-1 banks)"
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
    -name streamhost-plus4 \
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

# The Plus/4's BASIC screen is a white page inside a lavender border, so a live
# emulated TED fills most of the 800x600 root with bright pixels while a bare X
# root (or a dead xplus4) leaves it black.
PLUS4_MIN_BRIGHT=${PLUS4_MIN_BRIGHT:-100000}
wait_for_basic() {
  local name=$1
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      local bright
      bright=$(ppmhist "$EVIDENCE/$name.ppm" 2>/dev/null |
        awk '$1 > 96 && $2 > 96 && $3 > 96 { sum += $5 } END { print sum + 0 }')
      [ "$bright" -gt "$PLUS4_MIN_BRIGHT" ] && return 0
    fi
    sleep 2
  done
  die "no Plus/4 BASIC framebuffer after 180 seconds"
}

# The suite paints a BLACK page in yellow, so the ready test inverts. Measured
# on a clone: the empty word processor leaves ~5.7k non-black pixels, the
# spreadsheet's ruled grid ~36k, and the BASIC page is overwhelmingly white.
# "Plenty of ink, almost no white page" therefore identifies the spreadsheet
# and rejects both the BASIC prompt and a bare word-processor page.
wait_for_spreadsheet() {
  local name=$1
  for _ in $(seq 1 45); do
    if capture "$name" 2>/dev/null; then
      local ink white
      ink=$(ppmhist "$EVIDENCE/$name.ppm" 2>/dev/null |
        awk '$1 + $2 + $3 > 60 { sum += $5 } END { print sum + 0 }')
      white=$(ppmhist "$EVIDENCE/$name.ppm" 2>/dev/null |
        awk '$1 > 200 && $2 > 200 && $3 > 200 { sum += $5 } END { print sum + 0 }')
      [ "$ink" -gt 25000 ] && [ "$white" -lt 20000 ] && return 0
    fi
    sleep 2
  done
  die "3-plus-1 did not reach its spreadsheet with the chooser open"
}

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"
printf '%s\n' "$FIXTURE_PY" >"$FIXTURE_DRIVER"

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
  guest "command -v xplus4 >/dev/null" ||
    die "xplus4 missing from the bridge base (rebuild it with bridge-base.sh)"
  repair_plus4_roms
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  guest "pkill -u bridge xplus4 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  sleep 6
  wait_for_basic cold-boot-basic
fi

# One clean cold boot with the quiet console in force, then curate the fixture
# and bake it. Bake from a curated COLD boot, never from a screen that has
# carried verification output (the mpf2 add shipped one and had to re-bake).
stop_qemu
boot_tile
sleep 6
wait_for_basic ready-basic-prompt
guest "pgrep -x xplus4 >/dev/null" || die "xplus4 exited after cold boot"

# NOTHING IS TYPED BEFORE THE BAKE. The fixture is the untouched power-on
# screen; the driver below is kept only to prove, after the bake, that the
# route it advertises actually works.
capture ready-before-golden
bake_golden
sleep 3
wait_for_basic golden-restored

# Keyboard proof runs AFTER the bake, against the restored fixture, so nothing
# it types can ever reach the golden. It walks the WHOLE route the exhibit
# advertises -- F1+RETURN into the suite (what the power-on screen tells the
# visitor, and what the SPA's 3-PLUS-1 button sends), then C= + C and tc (what
# its Calc button sends) -- and asserts each step by what is actually on the
# screen: the suite is black where BASIC is a white page, and the spreadsheet's
# ruled grid is an order of magnitude more ink than an empty document. An
# earlier version asserted only "the framebuffer changed" and passed while its
# keystrokes went into the cell editor and typed a 0 into R1C1. A proof that
# cannot fail is not a proof.
keyboard_proof() {
  local base_hash proof_hash
  local white ink
  python3 "$FIXTURE_DRIVER" "$QMP" --suite-only
  sleep 3
  capture keyboard-1-suite
  white=$(ppmhist "$EVIDENCE/keyboard-1-suite.ppm" 2>/dev/null |
    awk '$1 > 200 && $2 > 200 && $3 > 200 { sum += $5 } END { print sum + 0 }')
  [ "$white" -lt 20000 ] ||
    die "F1+RETURN did not enter 3-plus-1 (white=$white; still the BASIC page)"
  log "keyboard proof 1/2: F1+RETURN entered the suite (white=$white)"

  python3 "$FIXTURE_DRIVER" "$QMP" --calc-only
  sleep 3
  capture keyboard-2-spreadsheet
  ink=$(ppmhist "$EVIDENCE/keyboard-2-spreadsheet.ppm" 2>/dev/null |
    awk '$1 + $2 + $3 > 60 { sum += $5 } END { print sum + 0 }')
  [ "$ink" -gt 25000 ] ||
    die "C= C then 'tc' did not reach the spreadsheet (ink=$ink; no grid drawn)"
  log "keyboard proof 2/2: C= C + tc reached the spreadsheet (ink=$ink)"

  hmp "loadvm golden" >/dev/null
  sleep 3
  wait_for_basic golden-restored-after-keyboard
}
keyboard_proof

log "PASS: Plus/4 power-on fixture, 3-plus-1 route proven, quiet console, golden"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT evidence=$EVIDENCE"
