#!/bin/bash
# irix-park-desktop.sh — park a NAMESPACED IRIX/MAME clone at a logged-in 4Dwm
# Indigo Magic desktop, and leave it running for someone else to measure.
#
# WHY THIS EXISTS
#   Several measurements (DRC crash soaks, 16 MB vs 256 MB desktop
#   responsiveness, anything about interactive behaviour) need a *held* desktop,
#   not a boot. Getting one by hand is a 5-minute cold boot that sometimes wedges
#   on a permanently black framebuffer, followed by a login the guest's widget
#   drops if you type it too fast. This script does all of that unattended:
#   boot, retry the black-screen hang, log in char-by-char, confirm the desktop
#   on the REAL framebuffer, and hand back the display number.
#
# Run ON the box (root@192.0.2.10). Everything lives under
# /data/vms/soltest/irix-park/<name>/ — never the production station tree — and
# every kill goes through clone-guard.
#
#   irix-park-desktop.sh start <name> [--display N] [--cpus LIST] [--chd PATH]
#                                     [--settle SECONDS]
#   irix-park-desktop.sh stop  <name>
#   irix-park-desktop.sh shot  <name> [out.png]
#
# The X display is ALLOCATED, not chosen: xvfb-alloc claims a free one atomically
# and start prints it (it is also recorded in <park dir>/display, which stop and
# shot read). Two parks started at the same second cannot land on the same
# display, and a park that cannot get its own display fails instead of quietly
# driving somebody else's. `--display N` pins one number for the rare case that
# needs it — and fails loudly if N is taken.
#
# Example (park a 256 MB desktop on physical core 3):
#   irix-park-desktop.sh start soak1 --cpus 3,11
#   irix-park-desktop.sh shot soak1 /tmp/soak1.png      # look at it
#   irix-park-desktop.sh stop soak1
set -u

ROOT="${IRIX_PARK_ROOT:-/data/vms/soltest/irix-park}"
ASSETS="${IRIX_ASSETS:-/data/vms/streamhost/assets/irix}"
MAME_BIN="${IRIX_MAME:-$ASSETS/mame/sgi}"
# The Lua input agent is the ONLY reliable keyboard channel: a WM-less
# full-screen Xvfb never mouse-captures, so SDL drops keys and buttons. Read it
# from the read-only ASSET stage, never from a live station's directory — a
# parameter-default pointing into /data/vms/streamhost/tiles is the exact
# footgun clone-guard refuses (and it once killed a production QEMU).
AGENT_SRC="${IRIX_AGENT:-$ASSETS/irixagent.lua}"

# The display allocator (box copy of scripts/lib/xvfb-alloc.sh). Sourcing it is
# mandatory: hand-picked display numbers are what let one park silently drive
# another park's framebuffer.
XVFB_ALLOC_LIB="${XVFB_ALLOC_LIB:-/usr/local/bin/xvfb-alloc}"
[ -f "$XVFB_ALLOC_LIB" ] || XVFB_ALLOC_LIB="$(dirname "$0")/../../lib/xvfb-alloc.sh"
# shellcheck disable=SC1090,SC1091 # resolved at run time (box copy or repo copy)
source "$XVFB_ALLOC_LIB" || {
  echo "irix-park-desktop: cannot source xvfb-alloc ($XVFB_ALLOC_LIB)" >&2
  exit 1
}

# Framebuffer signatures, measured on this exhibit at 1280x1024x24.
#
#   boot console      full mean 0.515-0.526  sd 0.211-0.219
#   PROM/early        full mean 0.595        sd 0.202
#   iconlogin chooser full mean 0.654-0.659  sd 0.226-0.231
#   bare X root       full mean 0.578        sd 0.157   toolchest-crop sd 0.095
#   4Dwm desktop      full mean 0.580        sd 0.163   toolchest-crop sd 0.257
#
# Note the last two: after a SUCCESSFUL login the X root paints SGI blue and
# sits there for minutes before 4Dwm draws the Toolchest, and full-frame mean
# and stddev barely move across that transition (0.578/0.157 -> 0.580/0.163).
# Full-frame statistics simply cannot tell "logged in, session still starting"
# from "logged in, desktop ready" -- and an earlier version of this script,
# which used them, both declared READY on a bare root and (worse) matched that
# same frame with its console/panic test and reported healthy logins as guest
# panics. So the desktop test is CONTENT-based: crop the Toolchest region and
# require real contrast there. 0.095 vs 0.257 is a 2.7x separation.
LOGIN_MEAN_MIN=0.60
LOGIN_SD_MIN=0.20
TOOLCHEST_CROP=130x230+0+30
TOOLCHEST_SD_MIN=0.18
BLACK_EPS=0.004

# The console/panic screen: white text in the console window on the SGI blue
# gradient. Bounded so it cannot overlap either the bare X root or the desktop
# (both sd ~0.16) or the login chooser (mean ~0.66).
CONSOLE_MEAN_MAX=0.62
CONSOLE_SD_MIN=0.19

INTERVAL=10
BOOT_DEADLINE="${IRIX_PARK_BOOT_DEADLINE:-1800}" # per attempt, wall seconds
BLACK_HITS=6                                     # x INTERVAL = 60 s of black => hung boot
GRACE=60
ATTEMPTS="${IRIX_PARK_ATTEMPTS:-5}"

# TYPING TOO SOON AFTER iconlogin APPEARS PANICS THE GUEST.
# The login panel paints well before the machine has finished coming up, and
# typing into it on a short fixed delay reproducibly kills IRIX with
#   PANIC: bad istack sp:8835afa8
# -- the SAME stack pointer every time, i.e. deterministic, and nothing to do
# with either the VC2 black-screen hang or the MAME DRC segfault. So wait for
# BOTH: the login signature has to hold still for SETTLE_STABLE consecutive
# samples (a readiness check, not a guess), AND at least SETTLE_MIN seconds have
# to have passed since the panel first appeared (a floor, because "looks stable"
# is exactly what it looks like while it is still starting services).
SETTLE_MIN="${IRIX_PARK_SETTLE:-120}"
SETTLE_STABLE=3

die() {
  echo "irix-park-desktop: $*" >&2
  exit 1
}

usage() {
  sed -n '2,30p' "$0" >&2
  exit 2
}

# --- framebuffer helpers ----------------------------------------------------
# All state detection is a real framebuffer grab. Never infer from logs.
fb_stat() { # $1 = display; echoes "<mean> <stddev>"
  local png="$D/.park.png"
  DISPLAY="$1" import -window root "$png" 2>/dev/null || return 1
  identify -format '%[fx:mean] %[fx:standard_deviation]' "$png" 2>/dev/null
}

is_black() { awk -v m="$1" -v e="$BLACK_EPS" 'BEGIN { exit !(m < e) }'; }
is_login() {
  awk -v m="$1" -v s="$2" -v mm="$LOGIN_MEAN_MIN" -v sm="$LOGIN_SD_MIN" \
    'BEGIN { exit !(m > mm && s > sm) }'
}
# Content-based: has 4Dwm actually drawn the Toolchest? Full-frame statistics
# cannot answer that (see the signature table above).
is_desktop() {
  local png="$D/.park.png" sd
  [ -f "$png" ] || return 1
  convert "$png" -crop "$TOOLCHEST_CROP" +repage "$D/.tc.png" 2>/dev/null || return 1
  sd="$(identify -format '%[fx:standard_deviation]' "$D/.tc.png" 2>/dev/null)" || return 1
  [ -n "$sd" ] || return 1
  awk -v s="$sd" -v m="$TOOLCHEST_SD_MIN" 'BEGIN { exit !(s > m) }'
}
is_console() {
  awk -v m="$1" -v s="$2" -v hi="$CONSOLE_MEAN_MAX" -v sm="$CONSOLE_SD_MIN" \
    'BEGIN { exit !(m < hi && s > sm) }'
}

log() { echo "$(date '+%F %T') $*" | tee -a "$D/park.log"; }

# A park that never reached a desktop must not leave an X server (and a display
# number) behind. A park that DID reach one is handed over deliberately.
PARK_READY=0
park_cleanup() {
  [ "$PARK_READY" = 1 ] && return 0
  clone-guard kill-pidfile "$D/mame.pid" >/dev/null 2>&1 || true
  xvfb_release "$D/xvfb.pid" >/dev/null 2>&1 || true
  rm -f -- "$D/display"
}

start_mame() {
  rm -f -- "$D/disk.chd"
  cp --reflink=always -- "$CHD" "$D/disk.chd"
  chmod 644 -- "$D/disk.chd"
  : >"$D/cmd"
  local pin=()
  [ -n "$CPUS" ] && pin=(taskset -c "$CPUS")
  DISPLAY="$DISP" SDL_VIDEODRIVER=x11 IRIX_CMD="$D/cmd" nohup \
    "${pin[@]}" \
    "$MAME_BIN" indy_4610 -bios b10 -rompath "$ASSETS/roms" -gio64_gfx xl24 \
    -hard1 "$D/disk.chd" \
    -nvram_directory "$D/nvram" -inipath "$ASSETS/uicfg" \
    -snapshot_directory "$D/snap" \
    -skip_gameinfo -video soft -sound none -mouse -background_input \
    -frameskip "${IRIX_FRAMESKIP:-6}" \
    -autoboot_script "$D/parkagent.lua" -autoboot_delay 0 \
    >"$D/mame.log" 2>&1 &
  echo "$!" >"$D/mame.pid"
  sleep 5
}

do_start() {
  mkdir -p "$D/nvram" "$D/snap"
  [ -f "$MAME_BIN" ] || die "missing MAME binary $MAME_BIN"
  [ -f "$CHD" ] || die "missing golden $CHD"
  [ -f "$AGENT_SRC" ] || die "missing input agent $AGENT_SRC"
  # Stage a private copy of the agent so a running park never reads (or races)
  # the asset-stage file, and wrap it in a geometry logger: the black-screen
  # boot hang is suspected to be MAME's VC2 leaving a degenerate screen size, so
  # every park that hits one should leave the evidence behind for free.
  cp -f "$AGENT_SRC" "$D/irixagent.lua"
  cat >"$D/parkagent.lua" <<EOF
-- generated by irix-park-desktop.sh: the input agent plus a geometry logger.
dofile("$D/irixagent.lua")
local gf = io.open("$D/geo.log", "a")
local glast = 0
emu.register_periodic(function()
  local t = os.time()
  if t == glast then return end
  glast = t
  local geo, emut = "?", -1
  pcall(function()
    for _, s in pairs(manager.machine.screens) do geo = s.width .. "x" .. s.height break end
    emut = manager.machine.time.seconds
  end)
  if gf then gf:write(string.format("%d emu=%d geo=%s\n", t, emut, geo)) gf:flush() end
end)
EOF
  cp -r "$ASSETS/nvram/." "$D/nvram/"

  # A parked desktop OUTLIVES this script (that is the whole point), so the
  # allocator's exit-release is off and the display is owned by the pidfile until
  # `stop`. The trap below still frees it if the park never reaches a desktop —
  # a failed park used to leak its Xvfb for as long as the box stayed up.
  local alloc=(--screen 1280x1024x24 --no-trap --tag "park-$NAME"
    --pidfile "$D/xvfb.pid" --log "$D/xvfb.log")
  [ -n "$DISPNUM" ] && alloc+=(--display "$DISPNUM")
  xvfb_alloc "${alloc[@]}" || die "could not allocate an X display"
  DISP="$XVFB_DISPLAY"
  printf '%s\n' "$DISP" >"$D/display"
  trap 'park_cleanup' EXIT INT TERM HUP
  log "allocated $DISP (chd=$CHD cpus=${CPUS:-unpinned})"

  local attempt=1 t0 t black stat mean sd stable login_t0 prev
  while :; do
    start_mame
    log "attempt $attempt: MAME pid $(cat "$D/mame.pid")"
    t0=$(date +%s)
    black=0
    stable=0
    login_t0=0
    prev=""
    while :; do
      sleep "$INTERVAL"
      t=$(($(date +%s) - t0))
      if ! [ -e "/proc/$(cat "$D/mame.pid")" ]; then
        log "attempt $attempt: MAME exited"
        break
      fi
      [ "$t" -ge "$BOOT_DEADLINE" ] && {
        log "attempt $attempt: boot deadline reached"
        break
      }
      stat="$(fb_stat "$DISP")" || continue
      mean="${stat%% *}"
      sd="${stat##* }"
      if is_black "$mean"; then
        [ "$t" -lt "$GRACE" ] && continue
        black=$((black + 1))
        [ "$black" -ge "$BLACK_HITS" ] && {
          log "attempt $attempt: black-screen hang at t=${t}s"
          break
        }
        continue
      fi
      black=0
      if is_login "$mean" "$sd"; then
        if [ "$login_t0" -eq 0 ]; then
          login_t0="$t"
          log "attempt $attempt: iconlogin chooser at t=${t}s (mean=$mean sd=$sd); settling"
        fi
        # Readiness, not a guess: the panel must stop changing AND the floor
        # must have elapsed. Typing early panics the guest (see SETTLE_MIN).
        if [ "$stat" = "$prev" ]; then stable=$((stable + 1)); else stable=0; fi
        prev="$stat"
        if [ "$stable" -lt "$SETTLE_STABLE" ] || [ $((t - login_t0)) -lt "$SETTLE_MIN" ]; then
          continue
        fi
        log "attempt $attempt: settled ($((t - login_t0))s, $stable stable samples); logging in"
        do_login && return 0
        log "attempt $attempt: login did not reach a desktop"
        break
      fi
      # A console screen AFTER the login panel appeared means the login attempt
      # took the guest down — most likely the `PANIC: bad istack` this script's
      # settle exists to avoid. Say so rather than silently retrying.
      if [ "$login_t0" -ne 0 ] && is_console "$mean" "$sd"; then
        DISPLAY="$DISP" import -window root "$D/panic-attempt$attempt.png" 2>/dev/null || true
        log "attempt $attempt: console/PANIC screen after login (mean=$mean sd=$sd) -> $D/panic-attempt$attempt.png"
        break
      fi
    done
    attempt=$((attempt + 1))
    [ "$attempt" -gt "$ATTEMPTS" ] && die "gave up after $ATTEMPTS boots (see $D/park.log)"
    clone-guard kill-pidfile "$D/mame.pid" >/dev/null 2>&1 || true
  done
}

# The Login-name widget drops fast natkeyboard input, so type one character per
# agent tick and let it settle before Enter. Empty password.
do_login() {
  local ch stat mean sd
  for ch in r o o t; do
    echo "POST $ch" >>"$D/cmd"
    sleep 0.8
  done
  sleep 2
  echo "CODE {ENTER}" >>"$D/cmd"
  # 4Dwm can take minutes to paint the Toolchest after the root appears.
  for _ in $(seq 1 60); do
    sleep "$INTERVAL"
    stat="$(fb_stat "$DISP")" || continue
    mean="${stat%% *}"
    sd="${stat##* }"
    # Desktop FIRST: a healthy login must never be mistaken for a failure.
    if is_desktop; then
      PARK_READY=1
      log "4Dwm desktop up (mean=$mean sd=$sd)"
      cat <<EOF
irix park '$NAME' READY
  display    DISPLAY=$DISP        (e.g. DISPLAY=$DISP import -window root out.png)
  mame pid   $(cat "$D/mame.pid")  (kill ONLY via: clone-guard kill-pidfile $D/mame.pid)
  input      echo 'POST hello' >> $D/cmd   # see irixagent.lua for the verbs
  logs       $D/park.log, $D/mame.log, $D/geo.log
  stop       $0 stop $NAME
EOF
      return 0
    fi
    if is_console "$mean" "$sd"; then
      DISPLAY="$DISP" import -window root "$D/panic-login.png" 2>/dev/null || true
      log "console/PANIC screen after typing (mean=$mean sd=$sd) -> $D/panic-login.png"
      return 1
    fi
  done
  return 1
}

do_stop() {
  clone-guard kill-pidfile "$D/mame.pid" >/dev/null 2>&1 || true
  # The allocator owns the X server: it verifies the pidfile's pid really holds
  # that display before signalling it, and clears the display's files after.
  xvfb_release "$D/xvfb.pid" >/dev/null 2>&1 || true
  rm -f -- "$D/display" "$D/disk.chd"
  echo "irix park '$NAME' stopped"
}

# --- argument handling ------------------------------------------------------
[ "$#" -ge 2 ] || usage
CMD_VERB="$1"
NAME="$2"
shift 2
case "$NAME" in
  *[!a-zA-Z0-9_-]* | '') die "invalid park name: $NAME" ;;
esac

DISPNUM="" # empty = allocate one from the pool (the normal case)
CPUS=""
CHD="$ASSETS/irix65-apps.chd"
OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --display)
      DISPNUM="$2"
      shift 2
      ;;
    --cpus)
      CPUS="$2"
      shift 2
      ;;
    --chd)
      CHD="$2"
      shift 2
      ;;
    --settle)
      SETTLE_MIN="$2"
      shift 2
      ;;
    *)
      OUT="$1"
      shift
      ;;
  esac
done

D="$ROOT/$NAME"
DISP="" # set by the allocator in do_start; read from $D/display afterwards
mkdir -p "$D"
# Fail closed if anyone points this at production.
clone-guard assert-path "$D" >/dev/null || die "park dir $D is outside the clone root"

case "$CMD_VERB" in
  start) do_start ;;
  stop) do_stop ;;
  shot)
    DISP="$(cat "$D/display" 2>/dev/null)"
    [ -n "$DISP" ] || die "park '$NAME' is not running (no $D/display)"
    DISPLAY="$DISP" import -window root "${OUT:-/tmp/irix-park-$NAME.png}" &&
      echo "${OUT:-/tmp/irix-park-$NAME.png}"
    ;;
  *) usage ;;
esac
