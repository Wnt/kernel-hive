#!/bin/bash
# irixbench workloads — how this rig drives IRIX, sourced by irixbench.sh.
#
# Kept out of irixbench.sh because that file was 40 lines from its hard size cap
# and these are a separable concern: irixbench.sh owns the run, the windows and
# the isolation; this owns what the guest is made to DO inside a window.
#
# Uses $D (run directory), $RIG, and the log/send/fb/mark/phase helpers from
# irixbench.sh. Not executable on its own.

# --- interactive workloads --------------------------------------------------
# The agent's motion verbs on the shm path are RELATIVE deltas, and an earlier
# revision of this rig concluded from that that named menu items are unreachable
# without closed-loop absolute positioning. They are not: the screen EDGE is an
# absolute reference. `MOVEP -2000 -2000` saturates the pointer into the
# top-left corner, and every gesture below is expressed as a delta from that
# corner — open-loop, but anchored, and therefore repeatable across boots.
#
# The coordinates are calibrated for golden v3's 4Dwm session at the 1288x1024
# emulated framebuffer and are NOT portable to another golden or resolution.
# Every workload is verified from the framebuffer before it is measured; a
# workload that cannot be confirmed on screen aborts the run rather than
# reporting a number for a gesture that missed.
CORNER="MOVEP -2000 -2000"
# A winterm covers a quarter of the screen in dark navy, so it moves the
# WHOLE-FRAME mean a long way: 0.619 at a bare 4Dwm desktop, 0.479 with the
# winterm open (measured on golden v3, both states screendumped beside the run).
# Do NOT decide this on a crop's standard deviation — the Toolchest sits inside
# any crop big enough to contain the window and carries enough structure on its
# own to clear an sd threshold, which is exactly how an earlier revision
# "confirmed" a winterm that had never opened.
WINTERM_MEAN_MAX=0.55

emu_wait() { # emu_wait <emulated seconds> — block until the guest's clock moves on
  local target
  target=$(awk -v n="$1" 'END{print $2 + n}' "$D/trace.txt")
  while awk -v t="$target" 'END{exit !($2 < t)}' "$D/trace.txt"; do
    sleep 10
    [ -e "/proc/$(cat "$D/mame.pid")" ] || return 1
  done
}

drive() { # drive <cmd>...  — one agent verb per line, with a settle gap
  local c
  for c in "$@"; do
    send "$c"
    sleep 0.4
  done
}

cursor() { python3 "$RIG/shmpng.py" "$D/fb.shm" --cursor 2>/dev/null; }

# CLOSED-LOOP absolute positioning on the shm path. The agent paces relative
# motion out at MOVE_STEP counts per emulated 40 ms window, so a large move
# takes emulated TIME to arrive — and a button verb travels a different queue
# and can be applied while the move is still draining. Sleeping a fixed wall
# interval between the two is a race that the guest wins whenever it is running
# slowly, which is exactly when this rig is under load: it is what made a
# Toolchest pick miss and abort a run. So: slam the corner, command the offset,
# then WATCH the cursor until it actually arrives before pressing anything.
point_to() { # point_to <x> <y>
  local wx=$1 wy=$2 i cx cy n
  send "$CORNER"
  sleep 4
  send "MOVEP $wx $wy"
  for i in $(seq 1 25); do
    sleep 2
    read -r cx cy n <<<"$(cursor)" || continue
    [ "${n:-0}" -gt 0 ] 2>/dev/null || continue
    # The cursor HOTSPOT is a few pixels from the red centroid, so this asks
    # "did it arrive", not "is it exact".
    if awk -v a="$cx" -v b="$cy" -v x="$wx" -v y="$wy" \
      'BEGIN{exit !((a-x)*(a-x)+(b-y)*(b-y) < 625)}'; then
      return 0
    fi
  done
  log "pointer never reached ($wx,$wy); last read ${cx:-?},${cy:-?}"
  return 1
}

# Toolchest -> Desktop -> "Open Unix Shell", as a spring-loaded menu drag:
# button DOWN on the "Desktop" entry at (40,48), pointer to "Open Unix Shell" at
# (180,228), button UP there. 4Dwm menus are posted only while the button is
# held, so a synthetic click cannot drive them — the press and the release have
# to be separate verbs with the motion between them.
open_shell() {
  log "opening a winterm from the Toolchest"
  point_to 40 48 || return 1
  drive "DOWN1"
  drive "MOVEP 140 180"
  sleep 4
  drive "UP1"
  local t=0 s w h mean sd tsd
  while [ $t -lt 180 ]; do
    sleep 10
    t=$((t + 10))
    s=$(fb "$D/shot-winterm.png") || continue
    read -r w h mean sd tsd <<<"$s"
    if awk -v m="$mean" -v x="$WINTERM_MEAN_MAX" 'BEGIN{exit !(m<x)}'; then
      log "t=${t}s winterm open (frame mean=$mean)"
      return 0
    fi
  done
  log "no winterm appeared — the Toolchest pick missed"
  return 1
}

# W1 terminal scroll. `find /usr -print` through a winterm is the canonical
# text-scroll workload for this exhibit: it is entirely Newport rendering plus
# guest scrolling, and it runs long enough to hold a window open.
w1_scroll() {
  send "POST repeat 400 find /usr -print"
  sleep 2
  send "CODE {ENTER}"
  sleep 20 # let it get going before the window opens
  phase w1 "$1"
}

# W2 window drag. Grab the winterm title bar and zigzag it. The gesture is
# regenerated for the whole hold so the drag never runs out partway through the
# measured window — an earlier run measured a "drag" that had already ended.
w2_drag() {
  local secs=$1 i
  point_to 120 14 || return 1
  drive "DOWN1"
  mark w2 start
  local end=$(($(date +%s) + secs))
  while [ "$(date +%s)" -lt "$end" ]; do
    for i in 1 2 3 4 5; do
      send "MOVEP 12 8"
      send "MOVEP -12 8"
      send "MOVEP -12 -8"
      send "MOVEP 12 -8"
    done
    sleep 1
  done
  mark w2 end
  fb "$D/shot-w2.png" >>"$D/fbtrace.txt"
  send "UP1"
}

# W3 Netscape. Launched from the winterm so no second menu pick is needed, then
# scrolled with Page Down. Netscape 4.7 on IRIX takes ~60 s to map its window.
w3_netscape() {
  local secs=$1 end
  send "POST /usr/bin/X11/netscape -no-about-splash file:/usr/share/catman/a_man/cat1 &"
  sleep 2
  send "CODE {ENTER}"
  sleep 90
  fb "$D/shot-w3-open.png" >>"$D/fbtrace.txt"
  mark w3 start
  end=$(($(date +%s) + secs))
  while [ "$(date +%s)" -lt "$end" ]; do
    send "CODE {PGDN}"
    sleep 1
  done
  mark w3 end
  fb "$D/shot-w3.png" >>"$D/fbtrace.txt"
}

# Clock drift. A timer change that makes the guest's own clock run fast or slow
# is not shippable however fast it is, so this is a gate, not a metric.
#
# The comparison is guest date against EMULATED seconds, not against the host
# wall clock. These runs are unthrottled, so host time and emulated time are
# deliberately unequal and a guest clock that tracked the host would be the
# broken outcome. The emulated-time reading comes from the same bench-agent
# trace every measurement window is cut from.
#
# Reading the guest's answer back means reading it off the framebuffer; there is
# no OCR here, so the screendumps are kept and compared by eye. Two samples ~600
# emulated seconds apart bound the drift rate to well under a part in a hundred,
# which is all this gate needs to decide.
drift_probe() {
  # The winterm must be at a PROMPT. `date` typed into a shell that is still
  # running W1's `repeat 400 find` is queued behind it and never appears, and
  # the screendump then shows scrolling paths where the clock should be — which
  # is exactly how the first attempt at this check produced two useless
  # screenshots. The dispatcher refuses drift-after-w1 for this reason; this is
  # the second line of defence.
  send "POST date"
  sleep 1
  send "CODE {ENTER}"
  sleep 5
  printf 'drift %s host=%s emu=%s\n' \
    "$1" "$(date +%s)" "$(tail -1 "$D/trace.txt" | awk '{print $2}')" >>"$D/drift.txt"
  fb "$D/shot-drift-$1.png" >>"$D/fbtrace.txt"
}
