#!/bin/bash
# =============================================================================
# stations/vision/vision-inner.sh — what runs INSIDE the vision station's
# sandbox (PID 2 of the systemd-nspawn container x11-runtime.sh starts; that
# file's header has the container's exact shape and the reasoning).
#
# In here:
#   1. start the pinned Xvfb whose socket directory is bound out to the host
#      for the daemon (-nolisten tcp: the abstract socket stays in this netns,
#      the filesystem socket lands in the bound-out directory);
#   2. start pce-ibmpc on it with its MONITOR wired to FIFOs under /work, so
#      the host can drive PCE (disk swaps: `di 0 /work/VOAPP2.psi`) and read
#      its output without entering this namespace;
#   3. set the input focus to PCE's window — Xvfb has no window manager, so the
#      default focus is PointerRoot and XTEST keys would follow the pointer;
#      an explicit focus makes the daemon's keystrokes land whatever the
#      pointer is doing;
#   4. wait for the screen to settle at the C:\> prompt and type VISION.
#
# GEOMETRY. PCE's x11 terminal draws CGA at `scale = 2` with its 4/3 aspect
# correction: 640x200 CGA becomes exactly 1280x800, so the Xvfb root IS the PCE
# window with nothing around it — no crop, no offset, root coordinates are
# window coordinates. Change `scale` in pce.cfg and VISION_GEOM together or the
# capture grows a border.
#
# NO GUESSED SLEEPS (rule 14). The waits here poll the framebuffer for a settle
# (two identical captures a second apart) rather than sleeping a fixed time.
#
# Paths are the container's:
#   $VISION_ASSETS  station assets, read-only, bound at their HOST path so the
#                   sandboxed pce-ibmpc's /proc/<pid>/exe reads as a host path
#                   and the daemon's SH_IDLE_PAUSE_PROC_MATCH still matches
#   /work           this launch's writable dir: hd0.pbi, VOAPP{1,2}.psi,
#                   pce.cfg, mon.in/mon.out, logs
#   /tmp/.X11-unix  bound to $BASE/x11 on the host (the daemon's door)
# Env from the launcher: VISION_DISPLAY (:94), VISION_GEOM (1280x800),
#   VISION_ASSETS, VISION_AUTOSTART (1)
# =============================================================================
set -euo pipefail
DISP="${VISION_DISPLAY:?}"
GEOM="${VISION_GEOM:-1280x800}"
N="${DISP#:}"
WORK=/work
log() { echo "$(date -u +%FT%TZ) vision-inner: $*"; }

chmod 1777 /tmp/.X11-unix 2>/dev/null || true
rm -f "/tmp/.X11-unix/X$N"

Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac \
  >"$WORK/xvfb.log" 2>&1 &
XPID=$!
for _ in $(seq 1 120); do
  [ -S "/tmp/.X11-unix/X$N" ] && break
  kill -0 "$XPID" 2>/dev/null || {
    log "Xvfb died:"
    cat "$WORK/xvfb.log"
    exit 1
  }
  sleep 0.25
done
[ -S "/tmp/.X11-unix/X$N" ] || {
  log "no X socket after 30 s"
  exit 1
}
log "Xvfb up on $DISP ($GEOM)"

export DISPLAY="$DISP"
cd "$WORK"

# PCE's monitor on a FIFO. Keep a persistent read-write fd open on it so PCE's
# stdin never sees EOF between commands: a plain `echo >mon.in` from the host
# closes its writer each time and PCE would take that as end of input.
rm -f mon.in
mkfifo mon.in
: >mon.out
exec 9<>mon.in

log "starting pce-ibmpc"
/opt/pce/bin/pce-ibmpc -c "$WORK/pce.cfg" <mon.in >mon.out 2>&1 &
PCEPID=$!
echo "$PCEPID" >pce.pid
# --- die on the FIRST SIGTERM -------------------------------------------------
# systemd-nspawn --kill-signal=SIGTERM delivers SIGTERM to pid 2, which is this
# script, and a plain `kill -TERM $PCEPID` is NOT enough: PCE installs its own
# signal handlers (SIGINT drops it into its monitor) and does not die on SIGTERM.
# Measured 2026-09-13: the container logged "Trying to halt container. Send
# SIGTERM again to trigger immediate termination" and stayed up for EIGHT MINUTES
# while x11-runtime.sh's reap_previous waited it out — reset on this station is
# `relaunch`, so that is a visitor staring at a frozen frame after
# `labctl reset vision`. Escalate to SIGKILL after a grace second. There is
# nothing to lose: PCE's ibmpc has no save state, the disk images are copied
# fresh from the pristine set on every launch, and .psi write-back on eject is
# irrelevant to a machine being torn down.
term_handler() {
  log "SIGTERM — stopping pce-ibmpc (pid $PCEPID)"
  kill -TERM "$PCEPID" 2>/dev/null || true
  for _ in 1 2 3 4; do
    kill -0 "$PCEPID" 2>/dev/null || break
    sleep 0.25
  done
  kill -KILL "$PCEPID" 2>/dev/null || true
  kill -TERM "$XPID" 2>/dev/null || true
  exit 0
}
trap term_handler TERM INT

# --- PCE's window, and the input focus ---------------------------------------
PCEWIN=""
for _ in $(seq 1 120); do
  kill -0 "$PCEPID" 2>/dev/null || {
    log "pce-ibmpc died at launch:"
    tail -20 mon.out
    exit 1
  }
  PCEWIN="$(xdotool search --name '^pce-ibmpc$' 2>/dev/null | head -1 || true)"
  [ -n "$PCEWIN" ] && break
  sleep 0.25
done
[ -n "$PCEWIN" ] || {
  log "no pce-ibmpc window after 30 s"
  tail -20 mon.out
  exit 1
}
# START THE CPU. pce-ibmpc comes up STOPPED at the monitor prompt (CS:IP =
# F000:FFF0, "type 'h' for help") and executes nothing until the monitor is told
# to go. Every frame before this is the blank power-on screen — a launcher that
# skips this waits forever for a DOS prompt that is never coming (measured
# 2026-09-13; it is the single easiest way to lose an hour on this station).
echo g >&9
log "sent 'g' to the PCE monitor — the 8088 is running"

xdotool windowfocus "$PCEWIN" 2>/dev/null || true
xdotool set_window --name "pce-ibmpc" "$PCEWIN" 2>/dev/null || true
log "pce-ibmpc pid $PCEPID window $PCEWIN focused; root $GEOM on $DISP"

# --- wait for the C:\> prompt by CONTENT, then start Visi On -----------------
# Two measurements make this section work, both taken on this station on
# 2026-09-13 and both reproducible with the commands in the wave doc:
#
#   INK. The fraction of non-black subpixels in the X root separates every
#   screen this boot passes through, with an order of magnitude between the
#   neighbours: the PC-DOS prompt sits at 39/10000, the prompt with VISION typed
#   at 47, the Visi On splash at 701, the Visi On desktop at 4570. So "has Visi
#   On started" is a measurement, not a guess.
#
#   BLINK. The prompt is the only screen here that oscillates: PC-DOS's cursor
#   blinks, so consecutive captures at the prompt alternate between exactly two
#   frames, forever (45 one-second captures produced exactly two hashes,
#   half-period ~2.5 s). A "settled screen" test can therefore NEVER be right on
#   this station, in either direction — it fires on the static POST screen and
#   it can never fire on the prompt. Two such heuristics were tried before this
#   one and both typed VISION into a screen that was not the prompt (the
#   keystrokes evaporated; the C:\> prompt sat untouched three minutes later).
#
# The prompt test is BOTH signals: the frame blinks between exactly two states
# AND both states carry prompt-band ink. And because no screen test is worth
# trusting alone, the whole thing is a RETRY loop closed on the ink measurement:
# if the splash has not appeared a few seconds after VISION was typed, the
# keystrokes went somewhere else and it types again. Typing VISION at a DOS
# prompt that is already busy is harmless — the worst case is a "Bad command"
# line and another attempt.
INK_PROMPT_LO=25 # the C:\> prompt measures 39; leave room for the typed line
INK_PROMPT_HI=120
INK_STARTED=200 # the Visi On splash measures 701, the desktop 4570

# fb_hash / fb_ink: one capture of the X root, hashed / measured. Ink is the
# fraction of non-zero bytes in the xwd payload, x10000. The rootfs carries no
# ImageMagick (it needs x11-apps for xwd and nothing more), so python3 does it.
fb_hash() { xwd -root -silent 2>/dev/null | sha256sum | cut -d' ' -f1; }
fb_ink() {
  xwd -root -silent 2>/dev/null | python3 -c 'import sys
d = sys.stdin.buffer.read()[4096:]
print(0 if not d else int(10000 * (len(d) - d.count(0)) / len(d)))'
}

# wait_dos_prompt <max-seconds>: blinking, in the prompt ink band.
wait_dos_prompt() {
  local max="${1:-180}" t0 h last ink i
  local -a runs=()
  t0="$(date +%s)"
  last="$(fb_hash)"
  runs=("$last")
  while [ $(($(date +%s) - t0)) -lt "$max" ]; do
    sleep 0.5
    h="$(fb_hash)"
    [ "$h" = "$last" ] && continue
    last="$h"
    runs+=("$h")
    i="${#runs[@]}"
    [ "$i" -ge 5 ] || continue
    # a-b-a-b-a: two distinct frames, four changes between them
    [ "${runs[i - 1]}" = "${runs[i - 3]}" ] && [ "${runs[i - 1]}" = "${runs[i - 5]}" ] &&
      [ "${runs[i - 2]}" = "${runs[i - 4]}" ] && [ "${runs[i - 1]}" != "${runs[i - 2]}" ] || continue
    ink="$(fb_ink)"
    if [ "$ink" -ge "$INK_PROMPT_LO" ] && [ "$ink" -le "$INK_PROMPT_HI" ]; then
      log "blinking text screen, ink=$ink — this is the C:\\> prompt"
      return 0
    fi
    log "blink seen but ink=$ink is outside the prompt band — not the prompt yet"
    runs=("$h")
  done
  return 1
}

# fb_settle <max-seconds>: two identical captures a second apart, after at least
# one change. Only used AFTER Visi On has started, where the screen really does
# go static — never to find the prompt, which never settles.
fb_settle() {
  local max="${1:-60}" first="" prev="" cur="" same=0 changed=0 i
  first="$(fb_hash)"
  for ((i = 0; i < max; i++)); do
    sleep 1
    cur="$(fb_hash)"
    [ "$cur" = "$first" ] || changed=1
    if [ "$cur" = "$prev" ]; then
      same=$((same + 1))
    else
      same=0
    fi
    prev="$cur"
    [ "$changed" = 1 ] && [ "$same" -ge 2 ] && return 0
  done
  return 1
}

# type_vision: one attempt. 120 ms per key is the measured drop-free pacing for
# PCE's 8088 keyboard scan (docs/lab/VISION-WAVE.md §Keyboard). VOAPP1 (the key
# disk) is already in A: — Visi On refuses to start without it.
type_vision() {
  xdotool type --window "$PCEWIN" --delay 120 'VISION'
  xdotool key --window "$PCEWIN" Return
}

# calibrate_pointer: walk the X pointer across the PCE window so Visi On sees
# mouse motion and leaves its "Calibrate the mouse." splash for the desktop, and
# then HOME the guest cursor onto the host pointer so absolute XTEST is 1:1.
#
# The walk is incremental because the no-grab patch reads the DELTA between
# successive MotionNotify events and spends the first event seeding its
# reference point (docs/lab/VISION-WAVE.md §Pointer).
#
# WHY THE HOMING SLAM, AND WHY IT IS EXACT. Visi On owns its own cursor and sees
# only Mouse Systems DELTAS, so the guest cursor and the host X pointer differ by
# a constant offset that depends on where the guest cursor happened to be when
# the emulator came up (measured 2026-09-13: (0,+40) px straight out of the
# calibration walk above — 40 px of error, twenty times the 2-px bar). Deltas
# alone can never remove that offset: both cursors move by the same amount.
# A CLAMP can. Slam the host pointer into the bottom-right corner and then into
# the top-left: the second move delivers a delta of (-1279,-799), larger than any
# possible guest cursor coordinate, so the guest cursor bottoms out at ITS (0,0)
# at the same moment the host pointer bottoms out at its own. The offset is zero
# from that instant, and stays zero, because the sync-alias clamp
# (patches/vision/pce-msys-sync-alias.patch) means no delta is ever dropped again.
# Measured after this homing: five targets, two laps, 0 px error on all ten.
#
# The slam must be two REAL moves, not a relative overshoot: a clamped X pointer
# emits no further MotionNotify, so an 8192-px relative slam delivers only the
# first few hundred pixels (docs/lab/VISION-WAVE.md §LISTING pass 3.3).
calibrate_pointer() {
  local x y
  xdotool mousemove --sync 640 400 || return 1
  for ((y = 400; y >= 140; y -= 20)); do
    xdotool mousemove --sync 640 "$y" || return 1
  done
  for ((x = 640; x >= 140; x -= 20)); do
    xdotool mousemove --sync "$x" 140 || return 1
  done
  return 0
}

# home_pointer: zero the guest-vs-host cursor offset by clamping both at (0,0).
# Runs after the desktop is up; see calibrate_pointer's comment for the why.
home_pointer() {
  local w h
  w="${GEOM%x*}"
  h="${GEOM#*x}"
  xdotool mousemove --sync $((w - 1)) $((h - 1)) || return 1
  xdotool mousemove --sync 0 0 || return 1
  # park in the middle so the first visitor does not start on a command-strip
  # button, and so the arrow is visible in the station's rest frame
  xdotool mousemove --sync $((w / 2)) $((h / 2)) || return 1
  return 0
}

if [ "${VISION_AUTOSTART:-1}" = 1 ]; then
  started=0
  for attempt in 1 2 3 4 5; do
    if ! wait_dos_prompt 180; then
      log "attempt $attempt: no blinking prompt in 180 s"
      continue
    fi
    log "attempt $attempt: typing VISION"
    type_vision
    # Visi On is up when the ink crosses out of the text-screen band.
    for _ in $(seq 1 20); do
      sleep 1
      ink="$(fb_ink)"
      if [ "$ink" -ge "$INK_STARTED" ]; then
        started=1
        break
      fi
    done
    [ "$started" = 1 ] && break
    log "attempt $attempt: no Visi On after 20 s (ink=$ink) — the keystrokes went nowhere; retrying"
  done
  if [ "$started" = 1 ]; then
    log "Visi On started (ink=$ink)"
  else
    log "Visi On never started after 5 attempts (ink=$ink)"
  fi

  if [ "$started" = 1 ] && [ "${VISION_CALIBRATE:-1}" = 1 ]; then
    fb_settle 30 && log "splash settled" || log "splash did not settle"
    if calibrate_pointer; then
      fb_settle 30 || true
      log "calibration walk done, ink=$(fb_ink)"
      if home_pointer; then
        log "pointer homed at (0,0) — guest cursor now tracks absolute XTEST 1:1"
      else
        log "pointer homing failed — absolute XTEST will carry a constant offset"
      fi
    else
      log "calibration walk failed"
    fi
  fi
fi

# `wait` returns >128 when a trap fires; loop until PCE is actually gone.
while kill -0 "$PCEPID" 2>/dev/null; do
  wait "$PCEPID" && break
  rc=$?
  [ "$rc" -gt 128 ] || break
done
log "pce-ibmpc exited"
kill -TERM "$XPID" 2>/dev/null || true
