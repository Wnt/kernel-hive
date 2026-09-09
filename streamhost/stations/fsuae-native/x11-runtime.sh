#!/bin/bash
# =============================================================================
# stations/fsuae-native/x11-runtime.sh — the SHARED launcher for host-native
# (de-bridged) FS-UAE stations: a3000, a1000 (amigaos35 and amix stay on the
# Xvfb+XTEST path for now — RTG and the in-guest X pointer are separate
# waves; do not point them at this launcher).
#
# Despite the historical filename there is NO X here: the fork
# (github.com/Wnt/fs-uae, branch kernel-hive/integrated) runs headless (no
# DISPLAY, no GL), publishes frames into $FSUAE_NATIVE_SHM (IFB1 header, same
# wire format drawshm/VICE_SHM_PATH use), takes input on the mamectl/1-style
# ctlsock at $FSUAE_NATIVE_CTL_SOCK, and writes audio into a named FIFO the
# streamhost daemon clocks. The name is the contract with
# ensure-station-x11.sh, which knows SH_CAPTURE=shm means "liveness =
# pidfile + mapping", not an X socket — exactly as
# stations/mame-native/x11-runtime.sh and stations/vice-native/x11-runtime.sh
# explain in their own headers; this launcher is modelled on both.
#
# ALL per-station knobs come from station.env (the systemd EnvironmentFile,
# already loaded when ExecStartPre runs us):
#   SH_STATION              station id == station dir name
#   SH_SHM_PATH              frame mapping ($BASE/fb.shm) -> FSUAE_NATIVE_SHM
#   SH_MAMECTL_SOCK          ctlsock path ($BASE/ctl.sock) -> FSUAE_NATIVE_CTL_SOCK
#   SH_AUDIO_FIFO            audio FIFO ($BASE/audio.fifo); empty = no audio
#                            -> FSUAE_NATIVE_AUDIO_FIFO
#   FSUAE_NATIVE_BIN         the host-native binary (assets/<tile>/fsuae-native/)
#   FSUAE_NATIVE_KICK        Kickstart ROM image
#   FSUAE_NATIVE_MODEL       --amiga_model value (A3000, A1000, ...)
#   FSUAE_NATIVE_MEM_ARGS    shell-quoted --chip_memory=/--fast_memory= etc.
#   FSUAE_NATIVE_HDF         golden hardfile name in $BASE/disk/, copied fresh
#                            to $BASE/work/ each launch; empty for a floppy
#                            station
#   FSUAE_NATIVE_FLOPPIES    space-separated golden ADF names in $BASE/disk/,
#                            copied to $BASE/work/ and passed as DF0, DF1, ...
#   FSUAE_NATIVE_EXTRA_ARGS  extra flags, shell-quoted string (eval'd)
#   FSUAE_NATIVE_STANDBY_DELAY_S  settle before the standby freeze (see below)
#   FSUAE_NATIVE_BASE        override for $BASE — rig/scratch runs outside a
#                            real station dir (e.g. a proof under
#                            /data/vms/sandbox/<name>/rig/); unset in
#                            production, where $BASE is always the tile dir.
#   SH_IDLE_PAUSE_PIDFILE/_SECS  the daemon's freezer; also arms standby here
#
# RESET = RELAUNCH: if a pidfile-owned emulator is alive we KILL it (verified
# through /proc/<pid>/exe, never a cmdline match) and start fresh from a
# fresh copy of the golden disk(s) — cold boot, no statefile. Golden + binary
# + device set are ONE combination (rule 6); a3000/a1000 do not yet carry a
# SAVEST/LOADST contract on this path (Part 3 risk #3 in
# docs/lab/FSUAE-NATIVE-BRIEF.md — mousehack one-event-late on restore, not
# yet measured on this launcher).
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${FSUAE_NATIVE_BASE:-/data/vms/streamhost/stations/$TILE}"
BIN="${FSUAE_NATIVE_BIN:?FSUAE_NATIVE_BIN not set in station.env}"
KICK="${FSUAE_NATIVE_KICK:?FSUAE_NATIVE_KICK not set}"
MODEL="${FSUAE_NATIVE_MODEL:?FSUAE_NATIVE_MODEL not set}"
SHM="${SH_SHM_PATH:-$BASE/fb.shm}"
CTL="${SH_MAMECTL_SOCK:-$BASE/ctl.sock}"
AFIFO="${SH_AUDIO_FIFO:-}"
PIDFILE="$BASE/mame.pid" # the shared pidfile name every native launcher uses

[ -x "$BIN" ] || {
  echo "fsuae-native[$TILE]: no binary at $BIN — run build-fsuae-native.sh" >&2
  exit 1
}
[ -f "$KICK" ] || {
  echo "fsuae-native[$TILE]: no Kickstart at $KICK" >&2
  exit 1
}

# Reap by /proc/<pid>/exe scoped to this station's asset dir; strip the
# " (deleted)" suffix a replaced binary leaves; SIGCONT before TERM (a
# SIGSTOPped emulator never runs to handle TERM); refuse to start over a
# survivor. Same guard, same two incidents, as mame-native/vice-native.
ASSET_DIR="$(dirname "$(readlink -f "$BIN")")"

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
rm -f "$PIDFILE" "$CTL"

mkdir -p "$BASE/work" "$BASE/disk"

# --- audio: resident FIFO holder, same shape as mame-native/vice-native ----
# A non-blocking writer needs a reader on the other end before it opens, or
# every disk-activity click starves; a resident holder keeps a read-write fd
# open forever so whichever side comes up first succeeds and a daemon
# restart never delivers SIGPIPE.
if [ -n "$AFIFO" ]; then
  [ -p "$AFIFO" ] || {
    rm -f -- "$AFIFO"
    mkfifo "$AFIFO"
  }
  if [ ! -f "$BASE/afifo-holder.pid" ] || ! kill -0 "$(cat "$BASE/afifo-holder.pid")" 2>/dev/null; then
    sleep infinity 3<>"$AFIFO" >/dev/null 2>&1 &
    echo $! >"$BASE/afifo-holder.pid"
  fi
fi

# --- media: fresh work copies from the golden(s), never the golden itself --
DISK_ARGS=()
if [ -n "${FSUAE_NATIVE_HDF:-}" ]; then
  GOLD="$BASE/disk/${FSUAE_NATIVE_HDF}.golden"
  [ -f "$GOLD" ] || {
    echo "fsuae-native[$TILE]: no golden hardfile at $GOLD" >&2
    exit 1
  }
  rm -f "$BASE/work/$FSUAE_NATIVE_HDF"
  cp --reflink=auto --sparse=always "$GOLD" "$BASE/work/$FSUAE_NATIVE_HDF"
  DISK_ARGS+=(--hard_drive_0="$BASE/work/$FSUAE_NATIVE_HDF")
fi
if [ -n "${FSUAE_NATIVE_FLOPPIES:-}" ]; then
  i=0
  for f in ${FSUAE_NATIVE_FLOPPIES}; do
    GOLD="$BASE/disk/$f"
    [ -f "$GOLD" ] || {
      echo "fsuae-native[$TILE]: no golden floppy at $GOLD" >&2
      exit 1
    }
    rm -f "$BASE/work/$f"
    cp --reflink=auto "$GOLD" "$BASE/work/$f"
    DISK_ARGS+=("--floppy_drive_${i}=${BASE}/work/${f}")
    i=$((i + 1))
  done
fi

MEM_ARGS=()
# shellcheck disable=SC2294 # the fixture value is a shell-quoted string on
# purpose, same convention as MAME_NATIVE_ARGS.
[ -n "${FSUAE_NATIVE_MEM_ARGS:-}" ] && eval 'MEM_ARGS=('"$FSUAE_NATIVE_MEM_ARGS"')'
EXTRA=()
[ -n "${FSUAE_NATIVE_EXTRA_ARGS:-}" ] && eval 'EXTRA=('"$FSUAE_NATIVE_EXTRA_ARGS"')'

# No X, no GL: the fork's second frontend (docs/lab/FSUAE-NATIVE-BRIEF.md
# Part 3, commit 2) is entered only because FSUAE_NATIVE_SHM is set below;
# with it unset the stock binary is byte-behaviourally identical and would
# still want a display. DISPLAY is unset here so a station accidentally
# built against the stock frontend fails LOUDLY instead of silently trying
# to open one.
unset DISPLAY
export FSUAE_NATIVE_SHM="$SHM"
export FSUAE_NATIVE_CTL_SOCK="$CTL"
[ -n "$AFIFO" ] && export FSUAE_NATIVE_AUDIO_FIFO="$AFIFO"
[ "${FSUAE_NATIVE_SHM_TRACE:-0}" = 1 ] && export FSUAE_NATIVE_SHM_TRACE=1

nohup "$BIN" \
  --amiga_model="$MODEL" \
  --kickstart_file="$KICK" \
  "${MEM_ARGS[@]}" \
  "${DISK_ARGS[@]}" \
  --fullscreen=0 \
  --automatic_input_grab=0 --initial_input_grab=0 \
  --floppy_drive_volume=0 \
  --mouse_integration=1 \
  --save_states=0 \
  --stdout=1 \
  "${EXTRA[@]}" \
  >"$BASE/fs-uae.log" 2>&1 &
echo $! >"$PIDFILE"

for _ in $(seq 1 40); do
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null || {
    echo "fsuae-native[$TILE]: fs-uae died at launch — tail of fs-uae.log:" >&2
    tail -20 "$BASE/fs-uae.log" >&2
    exit 1
  }
  [ -S "$CTL" ] && [ -s "$SHM" ] && break
  sleep 0.5
done
echo "fsuae-native[$TILE]: pid=$(cat "$PIDFILE") shm=$SHM ctl=$CTL audio=${AFIFO:-none} model=$MODEL (cold boot, no statefile)"

# ---------------------------------------------------------------------------
# STANDBY (instant-ready): an emulator nobody is watching must cost ~0 CPU.
# Same contract as mame-native/vice-native: freeze once the scene has
# settled, once the mapping actually shows it; the daemon owns the steady
# state from there (SH_IDLE_PAUSE_PIDFILE, unconditional SIGCONT on connect).
# Backgrounded so ExecStartPre returns promptly; the subshell lives in the
# unit's BindsTo scope. Only ever signals a pid whose /proc/<pid>/exe is
# still OUR binary.
# ---------------------------------------------------------------------------
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
