#!/bin/bash
# =============================================================================
# stations/a1000/x11-runtime.sh — host-native FS-UAE launcher for the Amiga
# 1000 station. Started by ensure-station-x11.sh inside the streamhost@a1000
# BindsTo scope. Same shape as amigaos35's launcher (pinned Xvfb sized to the
# emulator window, SH_CAPTURE=x11, XTEST input) with two differences:
#
#   * the guest boots from FLOPPIES, not a hardfile: disk/ holds the pristine
#     Workbench 1.2 and Extras ADFs, and every launch copies them into work/
#     (a visitor's writes never survive a reset);
#   * no statefile and no network: reset is a deterministic cold boot
#     (~55 s to the desktop), and a 1986 guest has no web plane to join.
#
# Per-station knobs from station.env:
#   SH_STATION / SH_X11_DISPLAY / FSUAE_NATIVE_BIN / FSUAE_NATIVE_GEOM as amigaos35
#   FSUAE_NATIVE_KICK       256 KB Kickstart 1.2 image in the ROM slot (proven route)
#   FSUAE_NATIVE_A1000_BOOTSTRAP  1 = the authentic path: FSUAE_NATIVE_BOOTROM (64 KB
#                           A1000 boot ROM) in the slot, the Kickstart image as a
#                           Kickstart DISK in DF0, Workbench in DF1. OPEN 2026-09-09:
#                           reset-loops in this build — keep 0 until proven.
#   FSUAE_NATIVE_STANDBY_DELAY_S / SH_IDLE_PAUSE_*   as amigaos35
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

# --- fresh work floppies from the pristine set ------------------------------
mkdir -p "$BASE/work"
for d in wb12.adf extras12.adf; do
  [ -f "$BASE/disk/$d" ] || {
    echo "fsuae-native[$TILE]: no golden floppy at $BASE/disk/$d" >&2
    exit 1
  }
  rm -f "$BASE/work/$d"
  cp --reflink=auto "$BASE/disk/$d" "$BASE/work/$d"
done

if [ "${FSUAE_NATIVE_A1000_BOOTSTRAP:-0}" = 1 ]; then
  # Authentic A1000: boot ROM in the slot, Kickstart loaded from a disk in DF0
  # (UAE synthesizes the Kickstart disk from the raw 262144-byte image), WB in DF1.
  BOOTROM="${FSUAE_NATIVE_BOOTROM:?FSUAE_NATIVE_BOOTROM not set}"
  cp --reflink=auto "$KICK" "$BASE/work/kick12.adf"
  ROM_ARGS=(--kickstart_file="$BOOTROM" --floppy_drive_0="$BASE/work/kick12.adf" --floppy_drive_1="$BASE/work/wb12.adf")
else
  ROM_ARGS=(--kickstart_file="$KICK" --floppy_drive_0="$BASE/work/wb12.adf" --floppy_drive_1="$BASE/work/extras12.adf")
fi

export DISPLAY="$DISP"
export LIBGL_ALWAYS_SOFTWARE=1 # no GPU: llvmpipe or FS-UAE gets no GL context
export SDL_VIDEODRIVER=x11
export ALSOFT_DRIVERS=null # audio plane is a follow-up; null device, no spam
W="${GEOM%x*}" H="${GEOM#*x}"

nohup "$BIN" \
  --amiga_model=A1000 \
  "${ROM_ARGS[@]}" \
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
echo "fsuae-native[$TILE]: pid=$(cat "$PIDFILE") display=$DISP geom=$GEOM bootstrap=${FSUAE_NATIVE_A1000_BOOTSTRAP:-0} (cold boot from floppies, no network)"

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
