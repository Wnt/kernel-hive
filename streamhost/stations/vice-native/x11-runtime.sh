#!/bin/bash
# =============================================================================
# stations/vice-native/x11-runtime.sh — the SHARED launcher for host-native
# (de-bridged) VICE stations: vic20, plus4, pet2001, cbm8032, cbm2, c128, c64.
#
# SKETCH, NOT YET LIVE. No station references this file: the wave's first
# conversion (vic20) wires it up together with the fork submodule and the
# builder. It is committed now because the daemon-side plumbing
# (SH_INPUT_BACKEND=vicesock, SH_VICESOCK_KEYMAP) is meaningless without the
# launcher half of the contract, and because the audio recipe below is the one
# place the MAME wave's shape must NOT be copied. See
# docs/lab/research/vice-daemon-plane.md.
#
# Modelled on stations/mame-native/x11-runtime.sh, and like it there is NO X:
# VICE is built --enable-headlessui, publishes frames into $SH_SHM_PATH
# (VICE_SHM_PATH, the identical IFB1 wire format drawshm uses), takes input on
# the vicectl unix socket, and writes audio into a named FIFO the streamhost
# daemon clocks. The filename is the contract with ensure-station-x11.sh, which
# knows SH_CAPTURE=shm means "liveness = pidfile + mapping", not an X socket.
#
# ALL per-station knobs come from station.env (the systemd EnvironmentFile):
#   SH_STATION              station id == station dir name
#   SH_SHM_PATH             frame mapping ($BASE/fb.shm)
#   SH_VICECTL_SOCK         vicectl control socket ($BASE/ctl.sock)
#   SH_VICESOCK_KEYMAP      the shared generated keysym table (aux-file copy)
#   SH_AUDIO_FIFO           audio FIFO ($BASE/audio.fifo); empty = no audio
#   VICE_NATIVE_BIN         the host-native binary (xvic/xplus4/xpet/...)
#   VICE_NATIVE_ARGS        machine flags, shell-quoted (e.g. -model 8032)
#   VICE_NATIVE_DATA        VICE's data tree (-directory): ROMs, palettes, .vkm
#   VICE_NATIVE_CHECKPOINT  0 opts out of restore-at-startup (cold boot)
#   VICE_NATIVE_STANDBY_DELAY_S  settle before the standby freeze
#   SH_KEY_MIN_HOLD_MS/_GAP_MS   per-key dwell floors, handed to the module
#   SH_IDLE_PAUSE_PIDFILE/_SECS  the daemon's freezer; also arms standby here
#
# RESET = RELAUNCH, restoring $BASE/sta/golden.vsf through the monitor's own
# playback file (-moncommands + -initbreak ready) — VICE has no -loadsnapshot.
# Unlike MAME there is no MACHINE_SUPPORTS_SAVE lottery: snapshot.c gates on
# machine name and per-module version and fails LOUDLY.
# =============================================================================
set -euo pipefail

STATION="${SH_STATION:?SH_STATION not set — run under streamhost@<station>}"
BASE="/data/vms/streamhost/stations/$STATION"
BIN="${VICE_NATIVE_BIN:?VICE_NATIVE_BIN not set in station.env}"
DATA="${VICE_NATIVE_DATA:?VICE_NATIVE_DATA not set}"
SHM="${SH_SHM_PATH:-$BASE/fb.shm}"
CTL="${SH_VICECTL_SOCK:-$BASE/ctl.sock}"
AFIFO="${SH_AUDIO_FIFO:-}"
PIDFILE="$BASE/vice.pid"

[ -x "$BIN" ] || {
  echo "vice-native[$STATION]: no binary at $BIN — run the builder" >&2
  exit 1
}

# Relaunch semantics: kill only what the pidfile names AND /proc proves is ours
# (never a cmdline match — it would match the shell running this script).
if [ -f "$PIDFILE" ]; then
  P="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$P" ] && [ "$(readlink -f "/proc/$P/exe" 2>/dev/null)" = "$(readlink -f "$BIN")" ]; then
    kill "$P" 2>/dev/null || true
    for _ in $(seq 1 40); do
      kill -0 "$P" 2>/dev/null || break
      sleep 0.25
    done
    kill -0 "$P" 2>/dev/null && kill -9 "$P" 2>/dev/null
  fi
fi
rm -f "$PIDFILE" "$CTL"
mkdir -p "$BASE/sta"

# ---------------------------------------------------------------------------
# AUDIO. NOT the MAME recipe. `-sound sdl -audiodriver disk` is right for MAME
# because MAME's disk driver is a dumb sink; VICE's `sdl` device is flagged
# is_timing_source=true, so pointing it at a pipe makes THE PIPE the emulator's
# clock — measured 24 % speed from the guest's own jiffy counter, and no
# buffer/fragment/pipe-size tuning moved it. `wav` is registered as a record
# device but accepted as playback, is not a timing source, and blocking-writes
# raw PCM: measured 98 % speed and the daemon's contract exactly
# (channels=2 rate=48000 byterate=192000 bits=16). It prepends a 44-byte RIFF
# header, which is 4-byte aligned so stereo s16 framing survives; the daemon
# eats ~11 frames of garbage at open. -soundoutput 2 is "always stereo" — 3 is
# a hard parse error.
# ---------------------------------------------------------------------------
SND=(-sounddev dummy)
if [ -n "$AFIFO" ]; then
  [ -p "$AFIFO" ] || { rm -f -- "$AFIFO" && mkfifo "$AFIFO"; }
  if [ ! -f "$BASE/afifo-holder.pid" ] || ! kill -0 "$(cat "$BASE/afifo-holder.pid")" 2>/dev/null; then
    # Resident O_RDWR holder: the emulator's open() must succeed whichever side
    # comes up first, and a daemon restart must never SIGPIPE the exhibit. This
    # is not optional — without it the writer took EPIPE, audio died for good,
    # and NOTHING was logged. stdio detached (an inherited stdout once held an
    # ssh session open for the holder's whole life).
    sleep infinity 3<>"$AFIFO" >/dev/null 2>&1 &
    echo $! >"$BASE/afifo-holder.pid"
  fi
  SND=(-sounddev wav -soundarg "$AFIFO" -soundrate 48000 -soundoutput 2)
fi

export VICE_SHM_PATH="$SHM"
export VICE_CTL_SOCK="$CTL"
# PER-KEY dwell floors, applied inside the module (the daemon's SH_KEY_MIN_*
# gate runs only on the QEMU/dbus path). EXCL is MANDATORY: these guests scan
# their own matrix, the browser sends a typed line as ONE burst, and the same
# 36-edge burst without it printed `N ''N`. Modifiers are exempt by matrix
# position, read from the .vkm's own !LSHIFT/!RSHIFT/!LCBM/!LCTRL anchors.
export VICE_CTL_KEY_EXCL=1
[ -n "${SH_KEY_MIN_HOLD_MS:-}" ] && export VICE_CTL_KEY_HOLD="$SH_KEY_MIN_HOLD_MS"
[ -n "${SH_KEY_MIN_GAP_MS:-}" ] && export VICE_CTL_KEY_GAP="$SH_KEY_MIN_GAP_MS"
unset DISPLAY

# Restore-at-startup: VICE has no -loadsnapshot, so the checkpoint is replayed
# through the monitor's own command file. The FIRST `x` ends playback, so this
# is one command block per file.
REST=()
if [ "${VICE_NATIVE_CHECKPOINT:-1}" = 1 ] && [ -f "$BASE/sta/golden.vsf" ]; then
  printf 'undump "%s"\nx\n' "$BASE/sta/golden.vsf" >"$BASE/sta/restore.mon"
  REST=(-moncommands "$BASE/sta/restore.mon" -initbreak ready)
fi

EXTRA=()
# shellcheck disable=SC2294 # the fixture value is a shell-quoted string on
# purpose, matching the MAME wave's MAME_NATIVE_ARGS.
[ -n "${VICE_NATIVE_ARGS:-}" ] && eval 'EXTRA=('"$VICE_NATIVE_ARGS"')'

# VICE 3.9/3.10 segfaults when stdout is not a terminal (vice_banner() ->
# strlen(NULL)); the fork carries the one-line log.c fix, and the redirect below
# is what would trip it on an unpatched build. Keep both.
nohup "$BIN" \
  -directory "$DATA" \
  "${SND[@]}" \
  ${REST[@]+"${REST[@]}"} \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  >"$BASE/vice.log" 2>&1 &
echo $! >"$PIDFILE"

for _ in $(seq 1 40); do
  [ -S "$CTL" ] && [ -s "$SHM" ] && break
  sleep 0.5
done
echo "vice-native[$STATION]: pid=$(cat "$PIDFILE") shm=$SHM ctl=$CTL audio=${AFIFO:-none} restore=${REST[*]:-none}"

# ---------------------------------------------------------------------------
# STANDBY (instant-ready): an emulator nobody is watching must cost ~0 CPU.
# The daemon owns the steady state through SH_IDLE_PAUSE_PIDFILE (SIGSTOP after
# the idle grace, unconditional SIGCONT on connect); what it cannot cover is the
# FIRST grace period, so freeze here once the scene has painted.
# Backgrounded — ExecStartPre must return promptly — and inside the unit's
# BindsTo scope, so `systemctl stop` takes it too. Only ever signals a pid whose
# /proc/<pid>/exe is still OUR binary.
# ---------------------------------------------------------------------------
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${VICE_NATIVE_STANDBY_DELAY_S:-8}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    [ "$(readlink -f "/proc/$p/exe" 2>/dev/null)" = "$(readlink -f "$BIN")" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "vice-native[$STATION]: standby — frozen at the scene (pid $p, ~0 CPU)"
  ) &
fi
