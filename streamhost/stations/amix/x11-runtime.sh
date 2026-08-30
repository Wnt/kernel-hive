#!/bin/bash
# =============================================================================
# stations/amix/x11-runtime.sh — host-native FS-UAE launcher for the Amiga
# UNIX (AMIX) station. Started by ensure-station-x11.sh inside the
# streamhost@amix BindsTo scope.
#
# Same shape as stations/amigaos35/x11-runtime.sh (stock FS-UAE under a pinned
# Xvfb, SH_CAPTURE=x11, XTEST input), with three deliberate differences:
#
#   1. The machine is an Amiga 3000 (68030 + MMU + 68882) with Kickstart 2.04
#      r37.175, not an A4000/040 — AMIX needs the 030 MMU.
#   2. The pointer is RELATIVE. amigaos35 gets an absolute pointer from the
#      UAE mousehack, but mousehack is an AmigaOS-level trap: AMIX drives the
#      Amiga mouse hardware directly and never registers, so host motion
#      arrives as accelerated relative deltas. Declared pointer=rel.
#   3. There is NO statefile. Reset is a cold boot of a fresh work disk copied
#      from the golden (~2 min to the OPEN LOOK desktop). The guest must be
#      halted with /sbin/shutdown before a golden is re-baked, or every boot
#      pays a full UFS fsck.
#
# Per-station knobs from station.env:
#   SH_STATION            amix
#   SH_X11_DISPLAY        the pinned display — daemon connects here
#   FSUAE_NATIVE_BIN      assets/amix/fsuae-native/bin/fs-uae
#   FSUAE_NATIVE_KICK     Kickstart 2.04 r37.175 (A3000) path
#   FSUAE_NATIVE_GEOM     WxH of window AND X screen (640x512)
#   FSUAE_NATIVE_STANDBY_DELAY_S  settle before the standby freeze
#   SH_IDLE_PAUSE_PIDFILE/_SECS   the daemon's freezer; also arms standby
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="/data/vms/streamhost/stations/$TILE"
BIN="${FSUAE_NATIVE_BIN:?FSUAE_NATIVE_BIN not set in station.env}"
KICK="${FSUAE_NATIVE_KICK:?FSUAE_NATIVE_KICK not set}"
GEOM="${FSUAE_NATIVE_GEOM:-640x512}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name, not a MAME claim

[ -x "$BIN" ] || {
  echo "fsuae-native[$TILE]: no binary at $BIN — run FSUAE_STATION=amix build-fsuae-native.sh" >&2
  exit 1
}
[ -f "$KICK" ] || {
  echo "fsuae-native[$TILE]: no Kickstart at $KICK" >&2
  exit 1
}

# Reap by /proc/<pid>/exe scoped to this station's asset dir; strip the
# " (deleted)" suffix; SIGCONT before TERM (a SIGSTOPped emulator never runs
# to handle TERM); refuse to start over a survivor.
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

# --- fresh work disk from the golden ----------------------------------------
# UFS carries no dirty flag we can repair from the host, so the golden must
# have been captured from a CLEANLY HALTED guest; a golden taken from a killed
# emulator makes every visitor's boot run fsck (~4 min instead of ~2).
mkdir -p "$BASE/work"
GOLD_HDF="$BASE/disk/amix-system.hdf.golden"
[ -f "$GOLD_HDF" ] || {
  echo "fsuae-native[$TILE]: no golden HDF at $GOLD_HDF" >&2
  exit 1
}
rm -f "$BASE/work/amix-system.hdf"
cp --reflink=auto --sparse=always "$GOLD_HDF" "$BASE/work/amix-system.hdf"

export DISPLAY="$DISP"
export LIBGL_ALWAYS_SOFTWARE=1 # no GPU: llvmpipe or FS-UAE gets no GL context
export SDL_VIDEODRIVER=x11
export ALSOFT_DRIVERS=null # audio plane is off for this station; null device
W="${GEOM%x*}" H="${GEOM#*x}"

# stretch=1 (FSE_STRETCH_FILL_SCREEN) — without it FS-UAE letterboxes the
# 640x512 Amiga screen inside its own window and the capture carries bars.
nohup "$BIN" \
  --amiga_model=A3000 \
  --kickstart_file="$KICK" \
  --motherboard_ram=16384 \
  --hard_drive_0="$BASE/work/amix-system.hdf" \
  --hard_drive_0_type=rdb \
  --hard_drive_0_controller=scsi6 \
  --fullscreen=0 --window_width="$W" --window_height="$H" \
  --stretch=1 \
  --automatic_input_grab=0 --initial_input_grab=0 \
  --floppy_drive_volume=0 \
  --stdout=1 \
  >"$BASE/fs-uae.log" 2>&1 &
echo $! >"$PIDFILE"

for _ in $(seq 1 40); do
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null || {
    echo "fsuae-native[$TILE]: fs-uae died at launch — tail of fs-uae.log:" >&2
    tail -20 "$BASE/fs-uae.log" >&2
    exit 1
  }
  grep -aq "uae_start" "$BASE/fs-uae.log" 2>/dev/null && break
  sleep 0.5
done
echo "fsuae-native[$TILE]: pid=$(cat "$PIDFILE") display=$DISP geom=$GEOM (cold boot, no statefile)"

# Standby: freeze once the booted scene has settled; the daemon owns the
# steady state via SH_IDLE_PAUSE_PIDFILE and SIGCONTs on the first session.
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${FSUAE_NATIVE_STANDBY_DELAY_S:-150}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = "$(readlink -f "$BIN")" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "fsuae-native[$TILE]: standby — frozen at the scene (pid $p; first session wakes it)"
  ) &
fi
