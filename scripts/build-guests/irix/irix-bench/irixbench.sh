#!/bin/bash
# irixbench.sh — measure IRIX-station emulation speed per WORKLOAD, within one run.
#
# WHY THIS EXISTS
#   Every IRIX perf claim on this project has to answer the same four questions,
#   and four retracted results came from getting one of them wrong:
#
#   1. WHAT metric?  emulated_secs / (cycles / 2.5e9) -- "cycnorm %", i.e. how
#      much of an SGI Indy second this host delivers per 2.5 GHz-second of CPU.
#      NEVER MAME's own "Average speed %": that is wall-clock based and moves
#      with every clock and scheduling change on a shared box.
#   2. At WHAT CLOCK?  cycnorm does not merely ignore the core clock, it INVERTS
#      it -- a 1.5 GHz run once scored +20% cycnorm while running 28% SLOWER in
#      real time. So achieved GHz (cycles / task-clock) is reported beside every
#      figure, and a run whose clock is out of family is discarded, not averaged.
#   3. Over WHAT window?  WITHIN ONE RUN only. IRIX boot diverges from ~t=120 s
#      (RTC seeded from the host clock), so differencing two runs is invalid.
#      Windows come from the emu-time/wall-time trace bench-agent.lua writes.
#   4. On WHAT CPU?  a full CORE PAIR, claimed. A busy SMT sibling costs MAME
#      39%, so the run records foreign occupancy on both logical CPUs and the
#      analyser flags any window that was not clean.
#
# PRODUCTION FIDELITY
#   Same binary, same golden, same flags as the live station (x11-runtime.sh):
#   `-video none` + shm publish, `-sound none`, `-frameskip 6`, the production
#   irixagent.lua as the input path. ONE deliberate difference: `-nothrottle`.
#   The station runs throttled, which clamps every regime at 100% and would make
#   the idle desktop unmeasurable; unthrottled is the only way to read a speed.
#   Pass --throttle to reproduce the shipped behaviour instead.
#
# ISOLATION
#   Everything under $BENCH_ROOT/<name>/ (never a live station directory), the
#   golden is only ever reflink-copied, and the MAME process is killed through
#   clone-guard by pidfile.
#
#   irixbench.sh run  <name> --cpus A,B [--chd P] [--bin P] [--phases LIST]
#   irixbench.sh stop <name>
#   irixbench.sh shot <name> [out.png]
set -u

BENCH_ROOT="${IRIX_BENCH_ROOT:-/data/vms/sandbox/irix-baseline-b7f2/run}"
ASSETS="${IRIX_ASSETS:-/data/vms/streamhost/assets/irix}"
RIG="${IRIX_BENCH_RIG:-/data/vms/sandbox/irix-baseline-b7f2/rig}"
MAME_BIN="${IRIX_MAME:-$ASSETS/mame/sgi}"
GOLDEN="${IRIX_GOLDEN:-$ASSETS/irix65-apps-v3.chd}"
# The agent the LIVE TILE runs, which is the station-directory copy — NOT
# $ASSETS/irixagent.lua. Those two had drifted: the assets copy still seeded the
# pointer accumulators at 32768, so the first MOVEP of a session presented a
# ~32768-count delta to a 9-bit PS/2 wire field, overflowed, and the cursor never
# moved again. Driving with it is what made an earlier revision of this rig
# conclude the interactive workloads were undrivable on golden v3; they are not.
# Production fidelity means the station's copy.
AGENT_SRC="${IRIX_AGENT:-/data/vms/streamhost/stations/irix/irixagent.lua}"
CG="${CLONE_GUARD:-/usr/local/bin/clone-guard}"

# Framebuffer signatures. NOTE these are NOT the numbers in
# scripts/build-guests/irix/irix-park-desktop.sh: that script grabs the Xvfb root,
# which is the emulated frame SCALED into a 1272x954 window inside a 1280x1024
# root with black borders. This rig reads the shm mapping, i.e. the EXACT
# 1288x1024 emulated framebuffer with no borders and no resample, and the
# whole-frame statistics move accordingly (the iconlogin chooser reads
# mean 0.702 sd 0.167 here versus 0.658/0.226 there). Re-measured on the shm
# path 2026-08-03; a screenshot of each state is kept beside the run.
#
# Readiness is decided on the TOOLCHEST CROP, not on full-frame statistics:
# after a successful login the X root paints SGI blue and sits there for minutes
# before 4Dwm draws the Toolchest, and full-frame mean/sd barely move across
# that transition. The crop separates them ~2.7x.
LOGIN_MEAN_MIN=0.68
TOOLCHEST_CROP=130x230+0+30
TOOLCHEST_SD_MIN=0.18
BLACK_EPS=0.004
SETTLE_MIN="${IRIX_BENCH_SETTLE:-120}"
SETTLE_STABLE=3
BOOT_DEADLINE="${IRIX_BENCH_BOOT_DEADLINE:-1500}"
# Seconds of UNBROKEN black framebuffer that count as the cold-boot hang.
BLACK_GIVEUP="${IRIX_BENCH_BLACK_GIVEUP:-180}"
INTERVAL=10

die() {
  echo "irixbench: $*" >&2
  exit 1
}
log() { echo "$(date +'%F %T') $*" | tee -a "$D/bench.log"; }

fb() { # fb [out.png] [crop] -> "w h mean sd crop_sd"; non-zero with no frame yet
  python3 "$RIG/shmpng.py" "$D/fb.shm" "${1:-}" --crop="${2:-$TOOLCHEST_CROP}" 2>/dev/null
}
send() { printf '%s\n' "$*" >>"$D/cmd"; }

# --- phase engine -----------------------------------------------------------
# A phase is: write a start marker, drive the guest, hold, write an end marker.
# The markers are host epochs; the analyser converts them to emulated-time
# windows through the trace, so a phase is a real within-run window.
mark() { printf '%s %s %.3f\n' "$1" "$2" "$(date +%s.%N)" >>"$D/phases.txt"; }
phase() { # phase <name> <seconds>
  local name=$1 secs=$2
  mark "$name" start
  sleep "$secs"
  mark "$name" end
  fb "$D/shot-$name.png" >>"$D/fbtrace.txt"
}

# The workloads themselves — see workloads.sh.
# shellcheck source=scripts/build-guests/irix/irix-bench/workloads.sh
. "$RIG/workloads.sh"

# The `sweep` phase — the MMIO-heavy regime.
#
# An idle 4Dwm desktop is dominated by the kernel idle loop, so a change that
# only speeds up RAM access reads optimistically there. `sweep` drags the
# pointer continuously across the root window for the whole hold: every motion
# is an X server cursor repaint, i.e. Newport register traffic through the
# memory system rather than RAM. It is the regime where an extra fastram entry
# (a cmp/jcc pair at the head of EVERY accessor stub) would show up as a LOSS,
# which is exactly why it has to be measured and not assumed.
#
# It is driven blind, with MOVEP (the agent's paced relative motion), so it
# needs no absolute positioning and works on golden v3.
#
# It is deliberately NOT one of the workloads.sh W1/W2/W3 workloads: those need
# a logged-in desktop with apps and drive real windows, this one needs nothing
# but the root window and so is available on every golden.
phase_sweep() { # phase_sweep <seconds>
  local secs=$1 t_end i=0
  mark sweep start
  t_end=$(($(date +%s) + secs))
  while [ "$(date +%s)" -lt "$t_end" ]; do
    # ~1800 counts/s, under the agent's MOVE_STEP/MOVE_WINDOW bleed rate
    # (3000/s) so nothing queues up and the rate is the same in both arms.
    if [ $(((i / 6) % 2)) -eq 0 ]; then send "MOVEP 180 40"; else send "MOVEP -180 -40"; fi
    i=$((i + 1))
    sleep 0.1
  done
  mark sweep end
  fb "$D/shot-sweep.png" >>"$D/fbtrace.txt"
}

cmd_run() {
  local name=$1
  shift
  local cpus="" phases="idle" hold=60 throttle=0 thr=() snd=none
  while [ $# -gt 0 ]; do
    case $1 in
      --cpus)
        cpus=$2
        shift 2
        ;;
      --chd)
        GOLDEN=$2
        shift 2
        ;;
      --bin)
        MAME_BIN=$2
        shift 2
        ;;
      --phases)
        phases=$2
        shift 2
        ;;
      --hold)
        hold=$2
        shift 2
        ;;
      --throttle)
        throttle=1
        shift
        ;;
      --sound)
        # The station ships `-sound none`. That is an OSD-SINK option: the emulated
        # HAL2/HPC3 audio path runs either way, so turning it on does not change
        # what the guest programs. This flag exists so that claim can be
        # measured rather than asserted.
        snd=$2
        shift 2
        ;;
      *) die "unknown argument $1" ;;
    esac
  done
  [ -n "$cpus" ] || die "--cpus A,B is required (claim the pair first)"
  [ "$throttle" = 1 ] || thr=(-nothrottle)
  D="$BENCH_ROOT/$name"
  case "$D" in /data/vms/sandbox/*) : ;; *) die "refusing to work outside /data/vms/sandbox" ;; esac
  rm -rf "$D"
  mkdir -p "$D"
  : >"$D/cmd"
  : >"$D/phases.txt"
  : >"$D/fbtrace.txt"
  : >"$D/bench.log"
  cp --reflink=auto -- "$GOLDEN" "$D/disk.chd"
  chmod 644 -- "$D/disk.chd"
  mkdir -p "$D/nvram"
  cp -r "$ASSETS/nvram/." "$D/nvram/"

  {
    echo "bin      $MAME_BIN  $(md5sum <"$MAME_BIN" | cut -c1-32)"
    echo "golden   $GOLDEN  $(md5sum <"$GOLDEN" | cut -c1-32)"
    echo "agent    $AGENT_SRC  $(md5sum <"$AGENT_SRC" | cut -c1-32)"
    echo "cpus     $cpus   throttle=$throttle   sound=$snd   phases=$phases hold=${hold}s"
  } >"$D/provenance.txt"

  # Per-second occupancy of BOTH logical CPUs of the pair, so a window that
  # shared its core pair with a foreign process can be discarded rather than
  # averaged in. This is the assertion the "busy sibling costs 39%" rule needs.
  (while :; do
    printf '%.3f %s\n' "$(date +%s.%N)" \
      "$(grep -E "^cpu(${cpus//,/|})\b" /proc/stat | tr '\n' '|')"
    sleep 1
  done) \
    >"$D/cpustat.txt" 2>/dev/null &
  echo $! >"$D/cpustat.pid"

  # MULTI-SAMPLE FRAMEBUFFER TRACE. A scheduling or timer change cannot be
  # validated with a single framebuffer checkpoint at a fixed emulated time:
  # under -frameskip 6 the control arm snapshots a black frame as often as the
  # treatment does, so a checkpoint md5 compares noise. What IS comparable is the
  # SEQUENCE — every arm must pass through the same screens in the same order at
  # roughly the same emulated times. This samples (emu_seconds, mean, sd) for the
  # whole run so two arms can be compared as trajectories.
  (while :; do
    printf '%s %s\n' "$(tail -1 "$D/trace.txt" 2>/dev/null | awk '{print $2}')" \
      "$(python3 "$RIG/shmpng.py" "$D/fb.shm" 2>/dev/null)"
    sleep 10
  done) >"$D/fbtrace-samples.txt" 2>/dev/null &
  echo $! >"$D/fbtrace.pid"

  date +%s.%N >"$D/perf.epoch"
  IRIX_SHM_PATH="$D/fb.shm" IRIX_CMD="$D/cmd" \
    IRIX_BENCH_AGENT="$AGENT_SRC" IRIX_BENCH_TRACE="$D/trace.txt" \
    perf stat -I 1000 -x, -e cycles,instructions,task-clock -o "$D/perf.csv" -- \
    taskset -c "$cpus" \
    "$MAME_BIN" indy_4610 -bios b10 -rompath "$ASSETS/roms" -gio64_gfx xl24 \
    -hard1 "$D/disk.chd" -nvram_directory "$D/nvram" -inipath "$ASSETS/uicfg" \
    -skip_gameinfo -video none -sound "$snd" -frameskip "${IRIX_FRAMESKIP:-6}" \
    "${thr[@]}" \
    -autoboot_script "$RIG/bench-agent.lua" -autoboot_delay 0 \
    >"$D/mame.log" 2>&1 &
  echo $! >"$D/perf.pid"
  # The pidfile must name the process whose death actually stops the emulator.
  # `perf stat -- ...` forks MAME as a grandchild through taskset and the glibc
  # bundle's loader, so killing the recorded `$!` leaves five orphaned MAMEs
  # burning 100% of a core each — which is exactly what happened the first time
  # this rig was run. Resolve the real emulator PID and record THAT.
  # `perf stat`'s own argv contains the whole MAME command line, so matching on
  # the command line alone finds perf, not the emulator — and killing perf is
  # precisely what leaves the orphan. Discriminate on /proc/<pid>/comm. Note the
  # emulator's comm is NOT `sgi`: it is exec'd through the glibc bundle's loader
  # and so reports `ld-linux-x86-64`. Exclude the wrappers rather than matching
  # a name that depends on how the binary happens to be launched.
  for _ in $(seq 1 30); do
    mpid=""
    for q in $(pgrep -f "indy_4610 -bios .*$D/disk.chd"); do
      case "$(cat "/proc/$q/comm" 2>/dev/null)" in
        perf | taskset | bash | sh | "") : ;;
        *) mpid=$q ;;
      esac
    done
    [ -n "$mpid" ] && break
    sleep 1
  done
  [ -n "${mpid:-}" ] || die "MAME did not appear; see $D/mame.log"
  echo "$mpid" >"$D/mame.pid"
  log "launched MAME pid $mpid (perf $(cat "$D/perf.pid")) on cpus $cpus, golden $(basename "$GOLDEN")"

  wait_desktop || {
    cmd_stop "$name"
    return 1
  }

  IFS=, read -r -a plist <<<"$phases"
  # Phases that need a shell get one ONCE, and the run aborts if the Toolchest
  # pick missed: a rig that silently measures an idle desktop and labels it
  # "terminal scroll" is worse than one that fails.
  case "$phases" in
    *w1* | *w2* | *w3* | *drift*)
      open_shell || {
        cmd_stop "$name"
        return 1
      }
      ;;
  esac
  for p in "${plist[@]}"; do
    log "phase $p (${hold}s)"
    case $p in
      idle) phase idle "$hold" ;;
      w1) w1_scroll "$hold" ;;
      w2) w2_drag "$hold" ;;
      w3) w3_netscape "$hold" ;;
      drift)
        # Fail closed rather than measure a shell that cannot answer: see
        # drift_probe. W1 leaves a long-running job in the only winterm.
        case "$phases" in
          *w1*)
            log "drift after w1 is invalid — the shell is still busy; skipping"
            continue
            ;;
        esac
        drift_probe a
        # Wait an EMULATED span, not a host one — see drift_probe.
        emu_wait "${IRIX_DRIFT_SPAN:-600}"
        drift_probe b
        ;;
      sweep) phase_sweep "$hold" ;;
      *) log "unknown phase $p — skipped" ;;
    esac
  done
  cmd_stop "$name"
  python3 "$RIG/bwin.py" "$D"
}

wait_desktop() {
  local t=0 stable=0 seen=0 first=0 blind=0 blackrun=0 s w h mean sd tsd
  while [ $t -lt "$BOOT_DEADLINE" ]; do
    sleep "$INTERVAL"
    t=$((t + INTERVAL))
    [ -e "/proc/$(cat "$D/mame.pid")" ] || {
      log "MAME died at t=${t}s"
      tail -5 "$D/mame.log"
      return 1
    }
    if ! s=$(fb); then
      # A rig that cannot see the framebuffer must say so. An earlier version
      # swallowed this with `|| continue` and, when an edit dropped
      # $TOOLCHEST_CROP, `set -u` made every read fail — so five runs sat
      # blind in this loop for ten minutes looking exactly like a slow boot.
      blind=$((blind + 1))
      if [ "$blind" -ge 6 ]; then
        log "cannot read the framebuffer ($blind samples running) — aborting"
        return 1
      fi
      continue
    fi
    blind=0
    read -r w h mean sd tsd <<<"$s"
    if awk -v m="$mean" -v e="$BLACK_EPS" 'BEGIN{exit !(m<e)}'; then
      log "t=${t}s black"
      # A boot that is still pure black this long after launch has hit the
      # known cold-boot hang and will never recover; waiting out BOOT_DEADLINE
      # costs ten minutes per failure and, when the failure RATE is the thing
      # being measured, that is most of the experiment. Fail fast and let the
      # caller count it.
      blackrun=$((blackrun + 1))
      if [ "$((blackrun * INTERVAL))" -ge "$BLACK_GIVEUP" ]; then
        log "black for $((blackrun * INTERVAL))s — cold-boot hang, giving up"
        return 1
      fi
      continue
    fi
    blackrun=0
    if [ "$seen" = 1 ] && awk -v x="$tsd" -v m="$TOOLCHEST_SD_MIN" 'BEGIN{exit !(x>m)}'; then
      log "t=${t}s DESKTOP READY (${w}x${h} mean=$mean sd=$sd toolchest_sd=$tsd)"
      fb "$D/shot-desktop.png" >>"$D/fbtrace.txt"
      return 0
    fi
    if [ "$seen" = 0 ] && awk -v m="$mean" -v n="$LOGIN_MEAN_MIN" 'BEGIN{exit !(m>n)}'; then
      stable=$((stable + 1))
      [ "$first" = 0 ] && first=$t
      log "t=${t}s login chooser (mean=$mean sd=$sd) stable=$stable"
      # TYPING TOO SOON AFTER iconlogin APPEARS PANICS THE GUEST ("PANIC: bad
      # istack", the same stack pointer every time). Require BOTH a held
      # signature AND a floor measured from when the panel FIRST appeared —
      # elapsed-since-launch is not the same thing and lets the floor pass
      # before the machine has finished coming up.
      if [ "$stable" -ge "$SETTLE_STABLE" ] && [ $((t - first)) -ge "$SETTLE_MIN" ]; then
        log "logging in (root, empty password)"
        # POST, not KEY: the agent's KEY verb takes a port and a field name
        # (`KEY <0|1> <port> <field>`), it does not take a character. And the
        # login-name widget drops fast natkeyboard characters, so one character
        # at a time with a gap — the same thing irix-park-desktop.sh does.
        for ch in r o o t; do
          send "POST $ch"
          sleep 0.5
        done
        send "CODE {ENTER}"
        seen=1
      fi
    fi
  done
  log "boot deadline reached without a desktop"
  return 1
}

cmd_stop() {
  D="$BENCH_ROOT/$1"
  [ -f "$D/cpustat.pid" ] && kill "$(cat "$D/cpustat.pid")" 2>/dev/null
  [ -f "$D/fbtrace.pid" ] && kill "$(cat "$D/fbtrace.pid")" 2>/dev/null
  # MAME first, then perf: perf flushes its last interval when the child exits.
  [ -f "$D/mame.pid" ] && "$CG" kill-pidfile "$D/mame.pid"
  sleep 2
  [ -f "$D/perf.pid" ] && "$CG" kill-pidfile "$D/perf.pid"
  rm -f "$D/cpustat.pid" "$D/fbtrace.pid"
  # Nothing named after this run may survive the stop. Verified, not assumed —
  # an orphaned MAME sits at 100% of a core forever and silently poisons every
  # measurement a sibling agent makes afterwards.
  if pgrep -f "indy_4610 -bios .*$D/disk.chd" >/dev/null; then
    echo "irixbench: WARNING — MAME for $1 survived the stop" >&2
    return 1
  fi
  return 0
}

cmd_shot() {
  D="$BENCH_ROOT/$1"
  fb "${2:-/tmp/irixbench-$1.png}"
}

case "${1:-}" in
  run)
    shift
    cmd_run "$@"
    ;;
  stop)
    shift
    cmd_stop "$@"
    ;;
  shot)
    shift
    cmd_shot "$@"
    ;;
  *)
    sed -n '2,45p' "$0" >&2
    exit 2
    ;;
esac
