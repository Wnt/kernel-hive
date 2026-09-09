#!/bin/bash
# =============================================================================
# stations/medley/x11-runtime.sh — host-native launcher for the Interlisp
# Medley station. Started by ensure-station-x11.sh inside the streamhost@medley
# BindsTo scope.
#
# THIS IS NOT AN EMULATED MACHINE. Medley is the Xerox D-machine Lisp
# environment (Interlisp-D / Common Lisp, 1980s) kept alive by the Interlisp
# project (github.com/Interlisp/medley, MIT); `maiko` is the byte-code VM
# that ran on Sun and Linux boxes from the 1990s on, and it renders the Lisp
# display straight into an X window. So the station is a stock X client under
# a pinned Xvfb: the daemon captures the X root (SH_CAPTURE=x11) and drives
# input over XTEST (SH_INPUT_BACKEND=x11test). X owns the pointer, so an
# XTEST warp IS the absolute pointer — no mousehack, no guest-X redirect, none
# of amix's slirp machinery.
#
# RESET = RELAUNCH: kill the pidfile-owned maiko (verified through
# /proc/<pid>/exe, never a cmdline match), wipe the per-launch work dir and
# start again from the pristine release sysout. Medley boots to its Exec in
# ~2 s from full.sysout, so a reset is faster than a QEMU loadvm. Nothing is
# ever written into the asset tree: LDEDESTSYSOUT (the SaveVM / LOGOUT target)
# and $HOME both point at $BASE/work.
#
# Per-station knobs from station.env:
#   SH_STATION            medley
#   SH_X11_DISPLAY        the pinned display — daemon connects here
#   MEDLEY_ASSETS         assets/medley (medley/ + maiko/ from the release tgz)
#   MEDLEY_GEOM           WxH of the Lisp screen AND the Xvfb (1024x768)
#   MEDLEY_SYSOUT         sysout to boot (default loadups/full.sysout)
#   MEDLEY_GREET          greet file (default greetfiles/MEDLEYDIR-INIT)
#   MEDLEY_MEM            maiko -m (MB of Lisp virtual memory; default 256)
#   MEDLEY_STANDBY_DELAY_S  settle before the standby freeze
#   SH_IDLE_PAUSE_PIDFILE/_SECS   the daemon's freezer; also arms standby
#
# Installed byte-for-byte as /data/vms/streamhost/stations/medley/x11-runtime.sh
# by scripts/streamhost-station.sh --x11. The runtime contract
# (ensure-station-x11.sh / stop-station-x11.sh) keys on FIXED pidfile names:
# the Lisp VM's pid lives in mame.pid (the x11-runtime pidfile name, not a
# claim that maiko is MAME) and its Xvfb in xvfb.pid. Kill ONLY by pidfile.
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${MEDLEY_BASE:-/data/vms/streamhost/stations/$TILE}"
ASSETS="${MEDLEY_ASSETS:-/data/vms/streamhost/assets/$TILE}"
GEOM="${MEDLEY_GEOM:-1024x768}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
MEM="${MEDLEY_MEM:-256}"
SYSOUT="${MEDLEY_SYSOUT:-$ASSETS/medley/loadups/full.sysout}"
GREET="${MEDLEY_GREET:-$ASSETS/medley/greetfiles/MEDLEYDIR-INIT}"
BIN="$ASSETS/maiko/linux.x86_64/ldex"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name, not a MAME claim

[ -x "$BIN" ] || {
  echo "medley[$TILE]: no maiko at $BIN — run scripts/build-guests/tiles/medley.sh" >&2
  exit 1
}
[ -f "$SYSOUT" ] || {
  echo "medley[$TILE]: no sysout at $SYSOUT" >&2
  exit 1
}

# Reap by /proc/<pid>/exe scoped to this station's asset dir; strip the
# " (deleted)" suffix; SIGCONT before TERM (a SIGSTOPped VM never handles
# TERM); refuse to start over a survivor.
station_vm_pids() {
  local d p exe
  for d in /proc/[0-9]*; do
    [ -d "$d" ] || continue
    p="${d#/proc/}"
    [ "$p" = "$$" ] && continue
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
    exe="${exe% (deleted)}"
    case "$exe" in
      "$ASSETS"/maiko/*) printf '%s\n' "$p" ;;
    esac
  done
}

reap_previous() {
  local p
  for p in $(station_vm_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  for _ in $(seq 1 40); do
    [ -z "$(station_vm_pids)" ] && return 0
    sleep 0.25
  done
  for p in $(station_vm_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null || true
  done
  sleep 0.5
  [ -z "$(station_vm_pids)" ]
}

reap_previous || {
  echo "medley[$TILE]: previous maiko still alive after SIGKILL:" \
    "$(station_vm_pids | tr '\n' ' ')— refusing to start a second one" >&2
  exit 1
}
rm -f "$PIDFILE"

# --- Xvfb: pinned display, atomically claimed -------------------------------
XPID="$(cat "$BASE/xvfb.pid" 2>/dev/null || true)"
if [ -n "$XPID" ] && [ "$(readlink "/proc/$XPID/exe" 2>/dev/null)" = "$(command -v Xvfb)" ] &&
  [ -S "/tmp/.X11-unix/X${DISP#:}" ]; then
  : # our Xvfb from a previous launch is still good
else
  # shellcheck source=/dev/null
  source /usr/local/bin/xvfb-alloc 2>/dev/null || source "$(dirname "$0")/../../scripts/lib/xvfb-alloc.sh"
  xvfb_alloc --display "${DISP#:}" --screen "${GEOM}x24" --pidfile "$BASE/xvfb.pid" --no-trap
  [ ":${XVFB_DISPLAY#:}" = ":${DISP#:}" ] || {
    echo "medley[$TILE]: allocator gave $XVFB_DISPLAY, wanted $DISP" >&2
    exit 1
  }
fi

# --- pristine per-launch state ----------------------------------------------
# The sysout is opened read-only by maiko; SaveVM/LOGOUT would write
# LDEDESTSYSOUT, which lives in work/ and is wiped on every launch.
rm -rf "$BASE/work"
mkdir -p "$BASE/work"
cd "$BASE/work" || exit 1

export DISPLAY="$DISP"
export MEDLEYDIR="$ASSETS/medley"
export HOME="$BASE/work"
export LOGINDIR="$BASE/work"
export LDEDESTSYSOUT="$BASE/work/lisp.virtualmem"
export LDEINIT="$GREET"
export LDESRCESYSOUT="$SYSOUT" # maiko reads the sysout from the env; a bare positional arg is refused
export LDEKBDTYPE=X            # maiko's X keyboard mapping (keysyms, not raw codes)

# The argument shape is run-medley's: -g is the X window, -sc the Lisp
# screen; equal and 4:3 so the capture is identity-mapped. -noscroll drops
# the scrollbars run-medley would otherwise pad the window with.
nohup "$BIN" -display "$DISP" -noscroll -g "$GEOM" -sc "$GEOM" \
  -title "Medley Interlisp" -m "$MEM" "$SYSOUT" \
  >"$BASE/maiko.log" 2>&1 &
echo $! >"$PIDFILE"

# maiko maps its window within ~1 s of exec; the Exec is drawn by ~2 s.
for _ in $(seq 1 40); do
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null || {
    echo "medley[$TILE]: maiko died at launch — tail of maiko.log:" >&2
    tail -20 "$BASE/maiko.log" >&2
    exit 1
  }
  xwininfo -root -tree -display "$DISP" 2>/dev/null | grep -q "Medley Interlisp" && break
  sleep 0.5
done
echo "medley[$TILE]: pid=$(cat "$PIDFILE") display=$DISP geom=$GEOM sysout=$(basename "$SYSOUT") (relaunch, no statefile)"

# Standby: freeze once the booted scene has settled; the daemon owns the
# steady state via SH_IDLE_PAUSE_PIDFILE and SIGCONTs on the first session.
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${MEDLEY_STANDBY_DELAY_S:-30}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = "$(readlink -f "$BIN")" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "medley[$TILE]: standby — frozen at the Exec (pid $p; first session wakes it)"
  ) &
fi
