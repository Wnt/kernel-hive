#!/bin/bash
# =============================================================================
# stations/a3000/x11-runtime.sh — host-native FS-UAE launcher for the Amiga
# 3000 station. Started by ensure-station-x11.sh inside the streamhost@a3000
# BindsTo scope. Same shape as amigaos35's launcher (pinned Xvfb sized to the
# emulator window, SH_CAPTURE=x11, XTEST input, fresh work HDF copied from the
# golden on every launch) minus the statefile and the retronet cage: reset is
# a deterministic cold boot of Workbench 2.04, and a 1991 guest has no web
# plane to join. Golden + binary + device set are ONE combination.
#
# Per-station knobs from station.env: as amigaos35 (FSUAE_NATIVE_BIN/_KICK/
# _GEOM, FSUAE_NATIVE_STANDBY_DELAY_S, SH_IDLE_PAUSE_*).
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="/data/vms/streamhost/stations/$TILE"
BIN="${FSUAE_NATIVE_BIN:?FSUAE_NATIVE_BIN not set in station.env}"
KICK="${FSUAE_NATIVE_KICK:?FSUAE_NATIVE_KICK not set}"
GEOM="${FSUAE_NATIVE_GEOM:-720x568}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name, not a MAME claim

[ -x "$BIN" ] || {
  echo "fsuae-native[$TILE]: no binary at $BIN — run build-fsuae-native.sh" >&2
  exit 1
}
[ -f "$KICK" ] || {
  echo "fsuae-native[$TILE]: no Kickstart at $KICK" >&2
  exit 1
}

# Reap by /proc/<pid>/exe scoped to this station's asset dir; strip the
# " (deleted)" suffix; SIGCONT before TERM (a SIGSTOPped emulator never runs
# to handle TERM); refuse to start over a survivor. Same guard as
# stations/mame-native/x11-runtime.sh, for the same two incidents.
ASSET_DIR="$(dirname "$(dirname "$(readlink -f "$BIN")")")"

station_emu_pids() {
  local d p exe
  for d in /proc/[0-9]*; do
    [ -d "$d" ] || continue
    p="${d#/proc/}"
    [ "$p" = "$$" ] && continue
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
    exe="${exe% (deleted)}"
    case "$exe" in
      "$ASSET_DIR"/*) printf '%s\n' "$p" ;;
    esac
  done
}

reap_previous() {
  local p
  for p in $(station_emu_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  for _ in $(seq 1 40); do
    [ -z "$(station_emu_pids)" ] && return 0
    sleep 0.25
  done
  for p in $(station_emu_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null || true
  done
  sleep 0.5
  [ -z "$(station_emu_pids)" ]
}

reap_previous || {
  echo "fsuae-native[$TILE]: previous emulator(s) still alive after SIGKILL:" \
    "$(station_emu_pids | tr '\n' ' ')— refusing to start a second publisher" >&2
  exit 1
}
rm -f "$PIDFILE"

# --- Xvfb: pinned display, atomically claimed -------------------------------
# xvfb-alloc's --display form still goes through the server's own kernel-
# atomic bind, so a sibling squatting :58 is a loud failure, never a silent
# attach. Reuse a live server only if OUR previous xvfb.pid still owns it.
XPID="$(cat "$BASE/xvfb.pid" 2>/dev/null || true)"
if [ -n "$XPID" ] && [ "$(readlink "/proc/$XPID/exe" 2>/dev/null)" = "$(command -v Xvfb)" ] &&
  [ -S "/tmp/.X11-unix/X${DISP#:}" ]; then
  : # our Xvfb from a previous launch is still good
else
  # shellcheck source=/dev/null
  source /usr/local/bin/xvfb-alloc 2>/dev/null || source "$(dirname "$0")/../../scripts/lib/xvfb-alloc.sh"
  xvfb_alloc --display "${DISP#:}" --screen "${GEOM}x24" --pidfile "$BASE/xvfb.pid" --no-trap
  [ ":${XVFB_DISPLAY#:}" = ":${DISP#:}" ] || {
    echo "fsuae-native[$TILE]: allocator gave $XVFB_DISPLAY, wanted $DISP" >&2
    exit 1
  }
fi

# --- fresh work disk from the golden pair -----------------------------------
mkdir -p "$BASE/work"
GOLD_HDF="$BASE/disk/a3000-system.hdf.golden"
[ -f "$GOLD_HDF" ] || {
  echo "fsuae-native[$TILE]: no golden HDF at $GOLD_HDF" >&2
  exit 1
}
rm -f "$BASE/work/a3000-system.hdf"
cp --reflink=auto --sparse=always "$GOLD_HDF" "$BASE/work/a3000-system.hdf"

export DISPLAY="$DISP"
export LIBGL_ALWAYS_SOFTWARE=1 # no GPU: llvmpipe or FS-UAE gets no GL context
export SDL_VIDEODRIVER=x11
export ALSOFT_DRIVERS=null # audio plane is a follow-up; null device, no spam
W="${GEOM%x*}" H="${GEOM#*x}"

nohup "$BIN" \
  --amiga_model=A3000 \
  --kickstart_file="$KICK" \
  --chip_memory=2048 --fast_memory=8192 \
  --hard_drive_0="$BASE/work/a3000-system.hdf" \
  --fullscreen=0 --window_width="$W" --window_height="$H" \
  --automatic_input_grab=0 --initial_input_grab=0 \
  --floppy_drive_volume=0 \
  --mouse_integration=1 \
  --save_states=0 \
  --stdout=1 \
  >"$BASE/fs-uae.log" 2>&1 &
echo $! >"$PIDFILE"

for _ in $(seq 1 40); do
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null || {
    echo "fsuae-native[$TILE]: fs-uae died at launch — tail of fs-uae.log:" >&2
    tail -20 "$BASE/fs-uae.log" >&2
    exit 1
  }
  grep -aq "uae_start\|mousehack registered" "$BASE/fs-uae.log" 2>/dev/null && break
  sleep 0.5
done
echo "fsuae-native[$TILE]: pid=$(cat "$PIDFILE") display=$DISP geom=$GEOM (cold boot of a fresh work HDF, no statefile, no network)"

# Standby: freeze once the restored scene has settled; the daemon owns the
# steady state via SH_IDLE_PAUSE_PIDFILE and SIGCONTs on the first session.
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${FSUAE_NATIVE_STANDBY_DELAY_S:-15}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = "$(readlink -f "$BIN")" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "fsuae-native[$TILE]: standby — frozen at the scene (pid $p; first session wakes it)"
  ) &
fi
