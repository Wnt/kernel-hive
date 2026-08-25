#!/bin/bash
# =============================================================================
# stations/amigaos35/x11-runtime.sh — host-native FS-UAE launcher for the
# AmigaOS 3.5 station. Started by ensure-station-x11.sh inside the
# streamhost@amigaos35 BindsTo scope.
#
# Unlike the MAME/VICE/es40 stations this one really DOES use X: stock
# (unpatched-for-video) FS-UAE renders into a pinned Xvfb sized exactly to
# the emulator window, the daemon captures the root with SH_CAPTURE=x11, and
# input arrives over XTEST (SH_INPUT_BACKEND=x11test with SH_X11TEST_ABS/
# _BUTTONS/_KEYS — the backend completed for this station). The only FS-UAE
# patch is the savestate mousehack re-arm (build-fsuae-native.sh), because a
# restore otherwise leaves the absolute mouse dead.
#
# Per-station knobs from station.env:
#   SH_STATION            amigaos35
#   SH_X11_DISPLAY        the pinned display (:58) — daemon connects here
#   FSUAE_NATIVE_BIN      assets/amigaos35/fsuae-native/bin/fs-uae
#   FSUAE_NATIVE_KICK     Kickstart ROM path (assets, never the repo)
#   FSUAE_NATIVE_GEOM     WxH of window AND X screen (720x568)
#   FSUAE_NATIVE_MOUSEHACK_ADDR  guest MH block addr paired with the golden
#                         (harvested from the bake log "mousehack registered")
#   FSUAE_NATIVE_CHECKPOINT      1 = restore sta/golden.uss at launch
#   FSUAE_NATIVE_NET      off | bsdsocket   (bsdsocket only inside the
#                         retronet netns wrapper — see rn-netns.sh when the
#                         station joins the web plane)
#   FSUAE_NATIVE_STANDBY_DELAY_S  settle before the standby freeze
#   SH_IDLE_PAUSE_PIDFILE/_SECS   the daemon's freezer; also arms standby
#
# RESET = RELAUNCH: the golden pair is sta/golden.uss + disk/amigaos35-
# system.hdf.golden. Every launch discards the previous session's disk by
# re-copying the golden HDF to work/ (UAE statefiles reattach hardfiles by
# path, and a visitor's disk writes must never survive a reset), then
# restores the statefile. Golden + HDF + binary + device set are ONE
# combination — recapture all together.
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
mkdir -p "$BASE/work" "$BASE/sta"
GOLD_HDF="$BASE/disk/amigaos35-system.hdf.golden"
[ -f "$GOLD_HDF" ] || {
  echo "fsuae-native[$TILE]: no golden HDF at $GOLD_HDF" >&2
  exit 1
}
rm -f "$BASE/work/amigaos35-system.hdf"
cp --reflink=auto --sparse=always "$GOLD_HDF" "$BASE/work/amigaos35-system.hdf"

STATE_ARGS=(--save_states=1 --state_dir="$BASE/sta")
if [ "${FSUAE_NATIVE_CHECKPOINT:-1}" = 1 ] && [ -f "$BASE/sta/Saved State 1.uss" ]; then
  STATE_ARGS+=(--load_state=1)
  # The re-arm address is PAIRED with the statefile (same boot lineage);
  # without it the restored guest's absolute mouse is dead.
  [ -n "${FSUAE_NATIVE_MOUSEHACK_ADDR:-}" ] && export FS_UAE_MOUSEHACK_ADDR="$FSUAE_NATIVE_MOUSEHACK_ADDR"
fi

NET_ARGS=()
NSWRAP=()
if [ "${FSUAE_NATIVE_NET:-off}" = bsdsocket ]; then
  # Retronet cage: bsdsocket host sockets are only ever opened INSIDE the
  # station netns (veth on vmbr-rn, no default route, guard chain) — never on
  # labhost's own stack. rn-netns.sh is idempotent and re-verifies its own
  # containment rules on every launch.
  bash "$BASE/rn-netns.sh" up || {
    echo "fsuae-native[$TILE]: rn-netns.sh up failed — refusing to start networked" >&2
    exit 1
  }
  NET_ARGS+=(--bsdsocket_library=1)
  NSWRAP=(ip netns exec "${RN_NS:-rn-amigaos35}")
fi

export DISPLAY="$DISP"
export LIBGL_ALWAYS_SOFTWARE=1 # no GPU: llvmpipe or FS-UAE gets no GL context
export SDL_VIDEODRIVER=x11
export ALSOFT_DRIVERS=null # audio plane is a follow-up; null device, no spam
W="${GEOM%x*}" H="${GEOM#*x}"

nohup ${NSWRAP[@]+"${NSWRAP[@]}"} "$BIN" \
  --amiga_model=A4000/040 \
  --kickstart_file="$KICK" \
  --chip_memory=2048 --zorro_iii_memory=8192 \
  --hard_drive_0="$BASE/work/amigaos35-system.hdf" \
  --fullscreen=0 --window_width="$W" --window_height="$H" \
  --automatic_input_grab=0 --initial_input_grab=0 \
  --floppy_drive_volume=0 \
  --mouse_integration=1 \
  --stdout=1 \
  "${STATE_ARGS[@]}" \
  ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
  >"$BASE/fs-uae.log" 2>&1 &
echo $! >"$PIDFILE"

for _ in $(seq 1 40); do
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null || {
    echo "fsuae-native[$TILE]: fs-uae died at launch — tail of fs-uae.log:" >&2
    tail -20 "$BASE/fs-uae.log" >&2
    exit 1
  }
  grep -aq "mousehack re-armed\|uae_start" "$BASE/fs-uae.log" 2>/dev/null && break
  sleep 0.5
done
echo "fsuae-native[$TILE]: pid=$(cat "$PIDFILE") display=$DISP geom=$GEOM checkpoint=${FSUAE_NATIVE_CHECKPOINT:-1} net=${FSUAE_NATIVE_NET:-off}"
grep -am1 "mousehack re-armed" "$BASE/fs-uae.log" || true

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
