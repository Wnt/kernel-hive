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
trap 'kill -TERM "$PCEPID" "$XPID" 2>/dev/null; exit 0' TERM INT

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

# --- wait for the screen to settle, then start Visi On -----------------------
# fb_settle <max-seconds>: returns when the screen has FIRST CHANGED from what
# it showed at t=0 and has then been identical across three consecutive samples
# a second apart. No fixed sleeps (rule 14).
#
# Both halves are load-bearing. Requiring a change first is what stops this
# returning instantly on the blank power-on screen — the 5160 spends its first
# seconds in POST with nothing on the CGA, two samples match, and a naive
# settle fires and types VISION into the BIOS. That happened on the first launch
# of this station (2026-09-13): PC-DOS reached C:\> perfectly and the VISION
# keystrokes had already been thrown away during memory count. Three samples
# rather than two covers the blinking cursor landing on the same phase twice.
fb_settle() {
  local max="${1:-60}" first="" prev="" cur="" same=0 changed=0 i
  first="$(xwd -root -silent | sha256sum | cut -d' ' -f1)"
  for ((i = 0; i < max; i++)); do
    sleep 1
    cur="$(xwd -root -silent | sha256sum | cut -d' ' -f1)"
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

if [ "${VISION_AUTOSTART:-1}" = 1 ]; then
  if fb_settle 90; then
    log "screen settled — assuming the C:\\> prompt; starting Visi On"
  else
    log "screen never settled in 90 s; starting Visi On anyway"
  fi
  # VOAPP1 (the key disk) is already in A:. Visi On refuses to start without it.
  # 120 ms per key is the measured drop-free pacing for PCE's 8088 keyboard
  # scan (docs/lab/VISION-WAVE.md §Keyboard).
  xdotool type --window "$PCEWIN" --delay 120 'VISION'
  xdotool key --window "$PCEWIN" Return
  log "typed VISION"
  fb_settle 120 && log "Visi On desktop settled" || log "Visi On desktop did not settle in 120 s"
fi

wait "$PCEPID" || true
log "pce-ibmpc exited"
kill -TERM "$XPID" 2>/dev/null || true
