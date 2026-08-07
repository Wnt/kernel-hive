#!/bin/bash
# slowrig.sh — does the IRIX exhibit enter a PERSISTENT slow state after a
# visitor has used a terminal, and if so, what is it?
#
# THE CLAIM UNDER TEST
#   After a terminal is used, the guest is reported to sit at 147k-166k
#   ASID-change + tlbwi events per EMULATED second — higher than during the
#   scroll itself — while IRIX's own `sar` calls the machine idle, holding ~42%
#   instead of ~85% for ten minutes or more. If true, every benchmark this
#   project has taken on a freshly parked desktop measures a state the exhibit
#   is often not in, and that outranks every optimisation on the list.
#
# HOW IT IS TESTED
#   One run, one guest, a timeline of windows: two idle windows BEFORE any
#   terminal exists, a scroll, then eight idle windows over the following ~13
#   emulated-clock minutes with nothing running. Within-run only — differencing
#   two IRIX boots is invalid on this exhibit and has manufactured three
#   retracted results — and the before/after windows are the same guest, the
#   same core pair and the same MAME process.
#
#   Each window is measured TWICE, back to back:
#     * a SPEED sub-window with no instrumentation attached at all, and
#     * a CENSUS sub-window with kernel uprobes counting the guest's ASID
#       changes and TLB writes.
#   They are separate because a uprobe costs a trap per hit: at 40k hits/s the
#   probes are 3-6% of host time, which is small but is not nothing, and a
#   speed figure taken while probing is a measurement of the probes.
#
# WHY UPROBES AND NOT AN INSTRUMENTED BUILD
#   The shipped MAME is unstripped with debug_info, so a kernel uprobe placed by
#   RAW ELF OFFSET counts exact events in the PRODUCTION binary with no rebuild.
#   (`perf probe`'s own symbol resolution fails on this binary — it parses the
#   C++ `::` as a line number — so the events are written straight into
#   /sys/kernel/tracing/uprobe_events.) The one instrumented MAME this project
#   built cost 2.35x and distorted every host-time number taken with it.
#   The probes are attached to a PRIVATE COPY of the binary: uprobes are keyed
#   by inode, so probing the shared asset copy would perturb every sibling
#   agent's measurement on this box.
#
# CONTROL CHANNEL
#   The console getty on IRIX /dev/ttyd1 (`-ioc2:rs232b pty`), not telnet. This
#   matters more than it looks: the earlier campaign that first saw slow "idle"
#   windows held a telnet session open THROUGH every window, including the ones
#   it labelled idle, so "a terminal was used" and "a login session exists" were
#   never separated in that data. Here the terminal is a background job on a
#   serial console and no network session exists at all.
#   (The newer v3-serial golden's in-guest exec agent does not answer -- measured
#   2026-08-03, PING times out -- and the shipped v3 golden has no guest
#   networking, so the getty is also the only channel that works on the image the
#   exhibit actually boots.)
#
#   slowrig.sh run  <name> --cpus A,B [--chd P] [--bin P] [--plan LIST]
#                          [--speed S] [--census S] [--posts N]
#   slowrig.sh stop <name>
#   slowrig.sh exec <name> "<line>"   # blind line on the console getty
#   slowrig.sh shot <name> [out.png]
set -u

SLOW_ROOT="${IRIX_SLOW_ROOT:-/data/vms/soltest/slowstate-7c1d/run}"
RIG="${IRIX_SLOW_RIG:-/data/vms/soltest/slowstate-7c1d/rig}"
BENCH_RIG="${IRIX_BENCH_RIG:-/data/vms/soltest/irix-baseline-b7f2/rig}"
ASSETS="${IRIX_ASSETS:-/data/vms/streamhost/assets/irix}"
MAME_BIN="${IRIX_MAME:-$RIG/sgi}"
# The SHIPPED golden, unmodified. Earlier drafts of this rig used the newer
# v3-serial build for its in-guest exec agent; the agent does not answer on that
# image, and the console getty works on the shipped one, so the rig measures what
# the exhibit actually boots instead.
GOLDEN="${IRIX_GOLDEN:-$ASSETS/irix65-apps-v3.chd}"
AGENT_SRC="${IRIX_AGENT:-$ASSETS/irixagent.lua}"
CG="${CLONE_GUARD:-/usr/local/bin/clone-guard}"
TRACEFS="${TRACEFS:-/sys/kernel/tracing}"

# Framebuffer signatures and the login rule are the baseline rig's, unchanged.
LOGIN_MEAN_MIN=0.68
TOOLCHEST_CROP=130x230+0+30
TOOLCHEST_SD_MIN=0.18
BLACK_EPS=0.004
SETTLE_MIN="${IRIX_SLOW_SETTLE:-120}"
SETTLE_STABLE=3
BOOT_DEADLINE="${IRIX_SLOW_BOOT_DEADLINE:-1500}"
INTERVAL=10

# Raw ELF st_values in the shipped `sgi`, verified with nm before every run (see
# assert_offsets). These are the DRC's C-call thunks, i.e. one hit per guest
# event, which is what makes the counts comparable with the earlier campaign's.
OFF_ASID=0x5f0800
OFF_TLBWI=0x5f0840
OFF_TLBWR=0x5f0830
OFF_CMPINT=0x5efe50
# Per-RUN event group. Two runs share one binary copy and therefore one inode,
# and a shared group name makes the second run's install fail with EEXIST (and,
# worse, makes a `probes off` from either one silently disarm the other).
UGROUP="${IRIX_SLOW_UGROUP:-irixss}"

die() {
  echo "slowrig: $*" >&2
  exit 1
}
log() { echo "$(date +'%F %T') $*" | tee -a "$D/rig.log"; }
send() { printf '%s\n' "$*" >>"$D/cmd"; }
fb() { python3 "$BENCH_RIG/shmpng.py" "$D/fb.shm" "${1:-}" --crop="$TOOLCHEST_CROP" 2>/dev/null; }
mark() { printf '%s %s %.3f\n' "$1" "$2" "$(date +%s.%N)" >>"$D/phases.txt"; }

# --- guest control ----------------------------------------------------------
# The CONSOLE getty on IRIX /dev/ttyd1 (`-ioc2:rs232b pty`), which is the channel
# the golden bakes were installed through and the only one that works on the
# SHIPPED golden: v3 has no guest networking and no in-guest exec agent. Wiring
# it costs one slot option on a clone and changes nothing else about the run.
#
# It is bidirectional here, unlike the "blind line" the bake rig sends: the
# getty's shell writes back to the same pty, so a reader process gives real
# captured output. Every command is therefore terminated by a marker and waited
# for, rather than slept on -- a fixed sleep would silently start the next phase
# in the middle of the previous command on a slow boot.
find_pts() {
  local p=$1 f idx
  for f in $(printf '%s\n' /proc/"$p"/fd/* | sort -t/ -k5 -n); do
    [ "$(readlink "$f" 2>/dev/null)" = /dev/ptmx ] || continue
    idx=$(awk '/^tty-index:/ {print $2}' "/proc/$p/fdinfo/$(basename "$f")")
    [ -n "$idx" ] && {
      echo "/dev/pts/$idx" >"$D/serial.pts"
      return 0
    }
  done
  return 1
}

console_start() {
  local pts
  pts="$(cat "$D/serial.pts")"
  # A pty slave defaults to ECHO ON, which would bounce every byte the guest
  # sends straight back into the guest.
  stty -F "$pts" raw -echo
  : >"$D/console.log"
  (cat "$pts" >>"$D/console.log" 2>/dev/null) &
  echo $! >"$D/console.pid"
}

# CR, not LF: the guest tty is in cooked mode with ICRNL, so a bare newline is
# not a line terminator there and the command would sit in the input buffer.
#
# PACED, one character at a time. The emulated IOC2 UART has no flow control and
# drops characters when a whole line is written into it at once: measured on this
# exhibit, `PATH=/usr/bin:/usr/sbin:...` arrived in the guest as
# `PATH/u/b:/usr/bi/sn:sr/bsd/u/e:$TH` and the shell answered `not found`. Short
# lines (`root`) survive, which is why the bake channel never hit this. 20 ms per
# character is ~5x the 9600-baud character time and has been clean since.
CSEND_GAP="${IRIX_SLOW_CSEND_GAP:-0.02}"
csend() {
  printf '%s' "$1" | python3 -c '
import sys, time
gap = float(sys.argv[2])
data = sys.stdin.buffer.read().replace(b"\n", b"\r") + b"\r"
with open(sys.argv[1], "wb", buffering=0) as f:
    for b in data:
        f.write(bytes([b]))
        time.sleep(gap)
' "$(cat "$D/serial.pts")" "$CSEND_GAP"
}

cwait() { # cwait <marker> <timeout_s>; true if it appeared
  local t=0
  while [ "$t" -lt "$2" ]; do
    grep -q -- "$1" "$D/console.log" && return 0
    sleep 2
    t=$((t + 2))
  done
  return 1
}

crun() { # crun <tag> <shell-line> <timeout_s>
  csend "$2; echo ${1}_ZZ\$?"
  cwait "${1}_ZZ" "$3" || log "WARNING: guest command $1 did not report back"
}

# Self-verifying rather than prompt-matching: type root, then ask the shell to
# say something only a shell would say. Boot chatter on this line contains both
# `login:` and `#`, so matching a prompt is not evidence of a shell.
console_login() {
  local t=0
  while [ "$t" -lt 300 ]; do
    csend ""
    sleep 3
    csend "root"
    sleep 3
    # IRIX's login asks `TERM = (vt100)` before it hands over the shell; a bare
    # Enter accepts the default. Without this the next line is eaten as a
    # terminal type and the loop needs an extra pass to recover.
    csend ""
    sleep 3
    csend "echo LOGIN_ZZ"
    sleep 4
    grep -q LOGIN_ZZ "$D/console.log" && {
      # root's login shell on this image is CSH, and every line of the workload
      # is Bourne: `VAR=x cmd` is a syntax error there, `>/dev/null 2>&1` is an
      # "Ambiguous output redirect", and both fail QUIETLY as far as the rig is
      # concerned -- the first run past this point measured an idle desktop and
      # called it a scroll. Switch the login shell out for /bin/sh before
      # anything else is typed.
      csend "exec /bin/sh"
      sleep 3
      csend "echo SH_ZZ"
      sleep 4
      grep -q SH_ZZ "$D/console.log" || log "WARNING: /bin/sh did not take over"
      log "console shell up after ${t}s"
      return 0
    }
    t=$((t + 13))
  done
  log "WARNING: no console shell on the getty line"
  return 1
}

# --- uprobes ----------------------------------------------------------------
# Fail closed on the offsets. A stale offset does not error: it silently probes
# some other function and produces a plausible number, which is the single
# worst failure mode an instrument can have.
assert_offsets() {
  local want got sym off
  for sym in "cfunc_mips3com_asid_changed:$OFF_ASID" \
    "cfunc_mips3com_tlbwi:$OFF_TLBWI" \
    "cfunc_mips3com_tlbwr:$OFF_TLBWR" \
    "compare_int_callback:$OFF_CMPINT"; do
    want=${sym##*:}
    # The demangled names are `cfunc_mips3com_tlbwi(void*)` but
    # `mips3_device::compare_int_callback(int)`, so anchor on either a space or
    # the class separator rather than assuming one of the two forms.
    got=$(nm -C "$MAME_BIN" | grep -E "( |::)${sym%%:*}\(" | awk '{print $1; exit}')
    off=$(printf '%016x' "$want")
    [ "$got" = "$off" ] || die "offset drift: ${sym%%:*} is 0x$got, rig says $want"
  done
}

probes_on() {
  [ -w "$TRACEFS/uprobe_events" ] || die "no $TRACEFS/uprobe_events (run as root)"
  probes_off
  {
    printf 'p:%s/asid %s:%s\n' "$UGROUP" "$MAME_BIN" "$OFF_ASID"
    printf 'p:%s/tlbwi %s:%s\n' "$UGROUP" "$MAME_BIN" "$OFF_TLBWI"
    printf 'p:%s/tlbwr %s:%s\n' "$UGROUP" "$MAME_BIN" "$OFF_TLBWR"
    printf 'p:%s/cmpint %s:%s\n' "$UGROUP" "$MAME_BIN" "$OFF_CMPINT"
  } >>"$TRACEFS/uprobe_events" || die "could not install uprobes"
}

probes_off() {
  local e
  for e in asid tlbwi tlbwr cmpint; do
    echo "-:$UGROUP/$e" >>"$TRACEFS/uprobe_events" 2>/dev/null
  done
  return 0
}

# --- the window engine ------------------------------------------------------
# speed sub-window: nothing attached. census sub-window: uprobes + PC sampler.
window() { # window <label>
  local label=$1 mpid
  mpid=$(cat "$D/mame.pid")
  mark "$label" start
  sleep "$SPEED_S"
  mark "$label" end
  fb "$D/shot-$label.png" >>"$D/fbtrace.txt"
  : >"$D/pcgate"
  mark "$label-c" start
  perf stat -x, -p "$mpid" -o "$D/census-$label.csv" \
    -e "$UGROUP:asid,$UGROUP:tlbwi,$UGROUP:tlbwr,$UGROUP:cmpint" \
    -- sleep "$CENSUS_S" 2>>"$D/rig.log"
  mark "$label-c" end
  rm -f "$D/pcgate"
  cp -f "$D/pc.log" "$D/pc-$label.log" 2>/dev/null
  : >"$D/pc.log"
  log "window $label done"
}

# The guest side of the terminal workload. Written once, before any window, so
# that building the corpus is never inside a measured window.
# shellcheck disable=SC2016  # IRIX-side shell text; expanded in the guest
GUEST_PREP='PATH=/usr/bin:/usr/sbin:/sbin:/usr/bsd:/usr/etc:$PATH; export PATH;
find /usr -print 2>/dev/null | head -20000 > /tmp/big.txt;
rm -rf /tmp/ch; mkdir /tmp/ch; cd /tmp/ch; split -l 250 /tmp/big.txt; cd /;
echo prepped=`wc -l < /tmp/big.txt`'

# shellcheck disable=SC2016  # IRIX-side shell text; expanded in the guest
GUEST_SCROLL='PATH=/usr/bin:/usr/sbin:/sbin:/usr/bsd:/usr/etc:$PATH; export PATH;
DISPLAY=:0.0 /usr/sbin/xwsh -geometry 80x40+40+40 -e /bin/sh -c "while : ; do for f in /tmp/ch/x* ; do cat \$f ; done ; done" >/dev/null 2>&1 &
sleep 3; ps -eo pid,comm | grep xwsh | head -3'

# shellcheck disable=SC2016  # IRIX-side shell text; expanded in the guest
GUEST_KILL='PATH=/usr/bin:/usr/sbin:/sbin:/usr/bsd:/usr/etc:$PATH; export PATH;
kill -9 `ps -eo pid,comm | awk '"'"'$2=="xwsh"{print $1}'"'"'` 2>/dev/null; sleep 2;
ps -eo pid,comm | grep -c xwsh'

cmd_run() {
  local name=$1
  shift
  local cpus="" posts=8
  SPEED_S=60
  CENSUS_S=30
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
      --speed)
        SPEED_S=$2
        shift 2
        ;;
      --census)
        CENSUS_S=$2
        shift 2
        ;;
      --posts)
        posts=$2
        shift 2
        ;;
      *) die "unknown argument $1" ;;
    esac
  done
  [ -n "$cpus" ] || die "--cpus A,B is required (claim the pair first)"
  UGROUP="${IRIX_SLOW_UGROUP:-irixss_$name}"
  D="$SLOW_ROOT/$name"
  case "$D" in /data/vms/soltest/*) : ;; *) die "refusing to work outside /data/vms/soltest" ;; esac
  assert_offsets
  rm -rf "$D"
  mkdir -p "$D/nvram"
  : >"$D/cmd"
  : >"$D/phases.txt"
  : >"$D/fbtrace.txt"
  : >"$D/rig.log"
  : >"$D/pc.log"
  cp --reflink=auto -- "$GOLDEN" "$D/disk.chd"
  chmod 644 -- "$D/disk.chd"
  cp -r "$ASSETS/nvram/." "$D/nvram/"
  {
    echo "bin      $MAME_BIN  $(md5sum <"$MAME_BIN" | cut -c1-32)"
    echo "shipped  $ASSETS/mame/sgi  $(md5sum <"$ASSETS/mame/sgi" | cut -c1-32)"
    echo "golden   $GOLDEN  $(md5sum <"$GOLDEN" | cut -c1-32)"
    echo "cpus     $cpus  speed=${SPEED_S}s census=${CENSUS_S}s posts=$posts"
  } >"$D/provenance.txt"

  (while :; do
    printf '%.3f %s\n' "$(date +%s.%N)" \
      "$(grep -E "^cpu(${cpus//,/|})\b" /proc/stat | tr '\n' '|')"
    sleep 1
  done) >"$D/cpustat.txt" 2>/dev/null &
  echo $! >"$D/cpustat.pid"

  probes_on
  date +%s.%N >"$D/perf.epoch"
  IRIX_SHM_PATH="$D/fb.shm" IRIX_CMD="$D/cmd" \
    IRIX_SLOW_BENCH="$BENCH_RIG/bench-agent.lua" \
    IRIX_BENCH_AGENT="$AGENT_SRC" IRIX_BENCH_TRACE="$D/trace.txt" \
    IRIX_SLOW_PCLOG="$D/pc.log" IRIX_SLOW_PCGATE="$D/pcgate" \
    perf stat -I 1000 -x, -e cycles,instructions,task-clock -o "$D/perf.csv" -- \
    taskset -c "$cpus" \
    "$MAME_BIN" indy_4610 -bios b10 -rompath "$ASSETS/roms" -gio64_gfx xl24 \
    -hard1 "$D/disk.chd" -ioc2:rs232b pty \
    -nvram_directory "$D/nvram" -inipath "$ASSETS/uicfg" \
    -skip_gameinfo -video none -sound none -frameskip "${IRIX_FRAMESKIP:-6}" \
    -nothrottle -autoboot_script "$RIG/slow-agent.lua" -autoboot_delay 0 \
    >"$D/mame.log" 2>&1 &
  echo $! >"$D/perf.pid"
  # perf forks MAME as a grandchild through taskset and the loader; killing the
  # recorded $! leaves an orphaned emulator at 100% of a core. Resolve the real
  # emulator pid on /proc/<pid>/comm (which is `ld-linux-x86-64`, not `sgi`).
  local q mpid=""
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
  [ -n "$mpid" ] || die "MAME did not appear; see $D/mame.log"
  echo "$mpid" >"$D/mame.pid"
  find_pts "$mpid" || die "no pty for the console line"
  console_start
  log "MAME pid $mpid on cpus $cpus, console $(cat "$D/serial.pts")"

  wait_desktop || {
    cmd_stop "$name"
    return 1
  }
  console_login
  crun PREP "$GUEST_PREP" 600
  grep -c . "$D/console.log" >>"$D/rig.log"

  window pre1
  window pre2
  crun SCROLL "$GUEST_SCROLL" 120
  window scroll
  crun KILL "$GUEST_KILL" 120
  local i
  for i in $(seq 1 "$posts"); do
    window "post$i"
    crun "PS$i" "ps -ef | wc -l; uptime" 60
  done

  cmd_stop "$name"
  python3 "$RIG/swin.py" "$D"
}

wait_desktop() {
  local t=0 stable=0 seen=0 first=0 blind=0 s w h mean sd tsd ch
  while [ $t -lt "$BOOT_DEADLINE" ]; do
    sleep "$INTERVAL"
    t=$((t + INTERVAL))
    [ -e "/proc/$(cat "$D/mame.pid")" ] || {
      log "MAME died at t=${t}s"
      tail -5 "$D/mame.log"
      return 1
    }
    if ! s=$(fb); then
      blind=$((blind + 1))
      [ "$blind" -ge 6 ] && {
        log "cannot read the framebuffer — aborting"
        return 1
      }
      continue
    fi
    blind=0
    read -r w h mean sd tsd <<<"$s"
    if awk -v m="$mean" -v e="$BLACK_EPS" 'BEGIN{exit !(m<e)}'; then
      log "t=${t}s black"
      continue
    fi
    if [ "$seen" = 1 ] && awk -v x="$tsd" -v m="$TOOLCHEST_SD_MIN" 'BEGIN{exit !(x>m)}'; then
      log "t=${t}s DESKTOP READY (${w}x${h} mean=$mean sd=$sd toolchest_sd=$tsd)"
      fb "$D/shot-desktop.png" >>"$D/fbtrace.txt"
      return 0
    fi
    if [ "$seen" = 0 ] && awk -v m="$mean" -v n="$LOGIN_MEAN_MIN" 'BEGIN{exit !(m>n)}'; then
      stable=$((stable + 1))
      [ "$first" = 0 ] && first=$t
      log "t=${t}s login chooser (mean=$mean sd=$sd) stable=$stable"
      # Typing too soon after iconlogin paints panics IRIX with the same stack
      # pointer every time, so wait for BOTH a held signature and a floor timed
      # from when the panel first appeared.
      if [ "$stable" -ge "$SETTLE_STABLE" ] && [ $((t - first)) -ge "$SETTLE_MIN" ]; then
        log "logging in (root, empty password)"
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
  # The event group is per-run, so a stop that did not re-derive it disarmed
  # nothing and left four uprobes on the binary for the next run to collide with.
  UGROUP="${IRIX_SLOW_UGROUP:-irixss_$1}"
  D="$SLOW_ROOT/$1"
  [ -f "$D/cpustat.pid" ] && kill "$(cat "$D/cpustat.pid")" 2>/dev/null
  [ -f "$D/console.pid" ] && kill "$(cat "$D/console.pid")" 2>/dev/null
  [ -f "$D/mame.pid" ] && "$CG" kill-pidfile "$D/mame.pid"
  sleep 2
  [ -f "$D/perf.pid" ] && "$CG" kill-pidfile "$D/perf.pid"
  rm -f "$D/cpustat.pid"
  probes_off
  if pgrep -f "indy_4610 -bios .*$D/disk.chd" >/dev/null; then
    echo "slowrig: WARNING — MAME for $1 survived the stop" >&2
    return 1
  fi
  return 0
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
  exec)
    D="$SLOW_ROOT/$2"
    csend "$3"
    ;;
  shot)
    D="$SLOW_ROOT/$2"
    fb "${3:-/tmp/slowrig-$2.png}"
    ;;
  probes)
    case "${2:-}" in
      on) probes_on ;;
      *) probes_off ;;
    esac
    ;;
  *)
    sed -n '2,52p' "$0" >&2
    exit 2
    ;;
esac
