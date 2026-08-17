#!/bin/bash
# =============================================================================
# stations/mame-native/x11-runtime.sh — the SHARED launcher for host-native
# (de-bridged) MAME stations. Installed into each station dir by the emitter
# (`--x11-runtime-file $T/mame-native/x11-runtime.sh`) and started by
# ensure-station-x11.sh inside the streamhost@<tile> BindsTo scope.
#
# Despite the historical filename there is NO X here: MAME runs headless
# (SDL_VIDEODRIVER=dummy), publishes frames into $SH_SHM_PATH (drawshm),
# takes input on the ctlsock socket, and writes audio into a named FIFO the
# streamhost daemon clocks (the irix audio contract). The name is the
# contract with ensure-station-x11.sh, which knows SH_CAPTURE=shm means
# "liveness = pidfile + mapping", not an X socket.
#
# ALL per-station knobs come from station.env (the systemd EnvironmentFile,
# already loaded when ExecStartPre runs us):
#   SH_STATION           tile id == station dir name
#   SH_SHM_PATH          drawshm mapping ($BASE/fb.shm)
#   SH_MAMECTL_SOCK      ctlsock path ($BASE/ctl.sock)
#   SH_AUDIO_FIFO        audio FIFO ($BASE/audio.fifo); empty/unset = no audio
#   MAME_NATIVE_BIN      the host-native binary (assets/<tile>/mame-native/)
#   MAME_NATIVE_DRIVER   machine name
#   MAME_NATIVE_ROMS     rompath
#   MAME_NATIVE_GEOM     published surface (MAME_SHM_SIZE)
#   MAME_NATIVE_ARGS     extra flags, shell-quoted string (eval'd: the Dragon
#                        needs a literal empty argument, `-ext ""`)
#   MAME_NATIVE_STANDBY_DELAY_S  settle before the standby freeze (see below)
#   SH_IDLE_PAUSE_PIDFILE/_SECS  the daemon's freezer; also arms standby here
#
# RESET = RELAUNCH: if a pidfile-owned emulator is alive we KILL it (verified
# through /proc/<pid>/exe, never a name match) and start fresh; with a
# captured checkpoint ($BASE/sta/<driver>/golden.sta — the stored label lags
# by design, docs/GLOSSARY.md) the fresh start RESTORES it — the QEMU
# fleet's `-loadvm golden`, translated to MAME. MAME_NATIVE_CHECKPOINT=0
# opts a station out (drivers without MACHINE_SUPPORTS_SAVE).
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="/data/vms/streamhost/stations/$TILE"
BIN="${MAME_NATIVE_BIN:?MAME_NATIVE_BIN not set in station.env}"
DRIVER="${MAME_NATIVE_DRIVER:?MAME_NATIVE_DRIVER not set}"
ROMS="${MAME_NATIVE_ROMS:?MAME_NATIVE_ROMS not set}"
GEOM="${MAME_NATIVE_GEOM:-1024x768}"
SHM="${SH_SHM_PATH:-$BASE/fb.shm}"
CTL="${SH_MAMECTL_SOCK:-$BASE/ctl.sock}"
AFIFO="${SH_AUDIO_FIFO:-}"
PIDFILE="$BASE/mame.pid"

[ -x "$BIN" ] || {
  echo "mame-native[$TILE]: no binary at $BIN — run build-mame-native.sh $TILE" >&2
  exit 1
}

# TWO PROVEN LIVE-VIDEO BUGS ARE FIXED HERE, both found on 2026-08-17 after a
# binary swap left plus4, cbm2 and cbm8032 (the VICE wave) with TWO emulators
# each, both still
# mapping the station's fb.shm and both still publishing. What the visitor saw
# was the golden frame every other frame and the real machine every other
# frame — the operator's "two machines at once".
#
#   1. `readlink -f /proc/$P/exe` on a REPLACED binary yields "<path>
#      (deleted)", which never equals "$BIN", so the old guard silently spared
#      exactly the process a deploy most needs to kill. Strip the suffix.
#   2. A standby emulator is SIGSTOPped, and a stopped process NEVER RUNS to
#      handle SIGTERM. It just sits there holding the mapping until the wait
#      loop gives up. SIGCONT first, then TERM, then KILL.
#
# And the pidfile is not the whole truth (a crashed launcher leaks one), so the
# sweep is over /proc, scoped to THIS station's own asset directory — the same
# anti-footgun as SH_IDLE_PAUSE_PROC_MATCH, and necessary because bbcmicro and armeval both run a
# binary called bbcb. Resolution is /proc/<pid>/exe, NEVER a cmdline
# match, which would match the shell running this script.
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

# FAIL LOUDLY rather than start a second publisher: a station that refuses to
# start is a visible outage someone fixes, while two publishers into one
# mapping is a subtle flicker nobody diagnoses.
reap_previous || {
  echo "mame-native[$TILE]: previous emulator(s) still alive after SIGKILL:" \
    "$(station_emu_pids | tr '\n' ' ')— refusing to start a second publisher" >&2
  exit 1
}
rm -f "$PIDFILE" "$CTL"

mkdir -p "$BASE/cfg" "$BASE/nvram" "$BASE/sta"

# MACHINE_NOT_WORKING/imperfect drivers nag on a red panel that would BE the
# exhibit; the skip-warnings build patch adds this ui.ini-only option.
if [ "${MAME_NATIVE_SKIP_WARNINGS:-0}" = 1 ]; then
  printf 'skip_warnings 1\n' >"$BASE/ui.ini"
fi

SND=(-sound none)
if [ -n "$AFIFO" ]; then
  [ -p "$AFIFO" ] || { rm -f -- "$AFIFO" && mkfifo "$AFIFO"; }
  if [ ! -f "$BASE/afifo-holder.pid" ] || ! kill -0 "$(cat "$BASE/afifo-holder.pid")" 2>/dev/null; then
    # Resident FIFO holder: keeps a read-write end open forever so SDL's
    # blocking open() succeeds whichever side comes up first and a daemon
    # restart never delivers SIGPIPE. stdio detached — an inherited stdout
    # held an ssh session open for the holder's whole life (2026-08-12).
    sleep infinity 3<>"$AFIFO" >/dev/null 2>&1 &
    echo $! >"$BASE/afifo-holder.pid"
  fi
  export SDL_DISKAUDIOFILE="$AFIFO"
  export SDL_DISKAUDIODELAY=0
  SND=(-sound sdl -audiodriver disk -samplerate 48000)
fi

export MAME_SHM_PATH="$SHM"
export MAME_SHM_SIZE="$GEOM"
export MAME_CTL_SOCK="$CTL"
# The exhibit is the guest's framebuffer and nothing else: no savestate
# popmessage ("Loaded state from ... Warning: Save states are not officially
# supported"), no FPS overlay, no menu, no paused banner. Emulator chrome on
# a 1982 screen is the wrong machine (mame-kiosk-no-ui.patch).
export MAME_NO_UI=1
# The module's PER-FIELD key dwell floors (a release waits this long after
# its own press; a re-press after its own release) derive from the station's
# bisected SH_KEY_MIN_* pacing — the same knobs labctl types with. The
# module defaults (100/50, IRIX's) are the fallback.
[ -n "${SH_KEY_MIN_HOLD_MS:-}" ] && export MAME_CTL_KEY_HOLD="$SH_KEY_MIN_HOLD_MS"
[ -n "${SH_KEY_MIN_GAP_MS:-}" ] && export MAME_CTL_KEY_GAP="$SH_KEY_MIN_GAP_MS"
# Separation between a modifier edge and the next character press, for guests
# whose keyboard is sampled by a controller rather than by the main CPU (the
# QL's 8049 IPC). Off unless the station's env asks for it.
[ -n "${SH_KEY_MOD_SEP_MS:-}" ] && export MAME_CTL_KEY_MOD_SEP="$SH_KEY_MOD_SEP_MS"
export SDL_VIDEODRIVER=dummy
unset DISPLAY

# MAME nests savestates per machine: the checkpoint (stored label `golden`,
# which lags by design — docs/GLOSSARY.md) lands in sta/<driver>/golden.sta
# (verified on the dragon32 cutover). MAME_NATIVE_CHECKPOINT=0 disables the
# restore for drivers WITHOUT MACHINE_SUPPORTS_SAVE: on those, -state golden
# restores garbage — bbcb died outright and kc85_4 restored to a black
# screen (2026-08-12, the operator's report). Their reset is the cold boot,
# which for every one of them reaches the documented power-on scene in
# seconds.
STARG=(-state_directory "$BASE/sta")
if [ "${MAME_NATIVE_CHECKPOINT:-1}" = 1 ] && [ -f "$BASE/sta/$DRIVER/golden.sta" ]; then
  STARG+=(-state golden)
fi

EXTRA=()
# shellcheck disable=SC2294 # the fixture value is a shell-quoted string on
# purpose: `-ext ""` must survive as a literal empty argument.
[ -n "${MAME_NATIVE_ARGS:-}" ] && eval 'EXTRA=('"$MAME_NATIVE_ARGS"')'

nohup "$BIN" "$DRIVER" \
  -rompath "$ROMS" -inipath "$BASE" -homepath "$BASE" \
  -cfg_directory "$BASE/cfg" -nvram_directory "$BASE/nvram" \
  -video shm -nofilter \
  "${SND[@]}" \
  -skip_gameinfo -throttle -frameskip 0 -noautoframeskip \
  "${STARG[@]}" \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  >"$BASE/mame.log" 2>&1 &
echo $! >"$PIDFILE"

for _ in $(seq 1 40); do
  [ -S "$CTL" ] && [ -s "$SHM" ] && break
  sleep 0.5
done
echo "mame-native[$TILE]: pid=$(cat "$PIDFILE") shm=$SHM ctl=$CTL audio=${AFIFO:-none} state=${STARG[*]}"
grep -m1 'ctlsock: setup' "$BASE/mame.log" || true

# ---------------------------------------------------------------------------
# STANDBY (instant-ready): an emulator nobody is watching must cost ~0 CPU.
# ---------------------------------------------------------------------------
# The fleet contract (docs/GLOSSARY.md "instant-ready"): launch restored-to-
# checkpoint and PAUSED; the first session resumes. The daemon owns the
# steady state through SH_IDLE_PAUSE_PIDFILE (SIGSTOP after the idle grace,
# and an UNCONDITIONAL SIGCONT on connect — idle.rs session_started, which is
# what makes a launcher-side freeze safe to hand over). What the daemon
# cannot do is cover the FIRST grace period: a station restarted at 03:00 and
# unvisited would burn a full core until its first idle tick. So freeze here,
# once the scene is actually on the mapping, and let the daemon take it from
# there.
#
# Backgrounded: ExecStartPre must return promptly, and this subshell lives in
# the unit's BindsTo scope, so `systemctl stop` takes it with everything else.
# Only ever signals a pid whose /proc/<pid>/exe is still OUR binary — the same
# stale-pid guard the daemon's freezer applies (idle.rs signal_pidfile).
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    # Let the scene settle before freezing it. A checkpoint restore paints in
    # ~1 s; a cold-boot station needs its ROM banner; armeval's autoboot types
    # two supervisor lines at ~16 emulated seconds. Per-station via the
    # fixture, because only the station knows when its scene is DONE.
    sleep "${MAME_NATIVE_STANDBY_DELAY_S:-8}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    [ "$(readlink -f "/proc/$p/exe" 2>/dev/null)" = "$(readlink -f "$BIN")" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "mame-native[$TILE]: standby — frozen at the scene (pid $p, ~0 CPU; first session wakes it)"
  ) &
fi
