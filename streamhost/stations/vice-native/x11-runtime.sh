#!/bin/bash
# =============================================================================
# stations/vice-native/x11-runtime.sh — the SHARED launcher for host-native
# (de-bridged) VICE stations: vic20, plus4, pet2001, cbm8032, cbm2, c128, c64.
#
# LIVE since the vic20 conversion (2026-08-16), which is the wave's template:
# the fork submodule (third_party/vice-kernel-hive), the builder
# (scripts/build-guests/emulators/build-vice-native.sh) and this launcher are
# one contract. The audio recipe below is the one place the MAME wave's shape
# must NOT be copied. See docs/lab/research/vice-daemon-plane.md.
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
#   VICE_NATIVE_SHM_CHIP    which canvas publishes on a two-canvas machine (c128)
#   VICE_NATIVE_ATTACH8     disk image to put in drive 8 AFTER the restore (c128)
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
# TWO PROVEN LIVE-VIDEO BUGS ARE FIXED HERE, both found on 2026-08-17 after a
# binary swap left plus4, cbm2 and cbm8032 with TWO emulators each, both still
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
# anti-footgun as SH_IDLE_PAUSE_PROC_MATCH, and necessary because xpet serves
# both pet2001 and cbm8032. Resolution is /proc/<pid>/exe, NEVER a cmdline
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
  echo "vice-native[$STATION]: previous emulator(s) still alive after SIGKILL:" \
    "$(station_emu_pids | tr '\n' ' ')— refusing to start a second publisher" >&2
  exit 1
}
rm -f "$PIDFILE" "$CTL"
mkdir -p "$BASE/sta"

# THE LANDMINE, and it is a LAUNCHER requirement, not a version quirk: a
# headless VICE whose stdout is not a tty SEGFAULTS in vice_banner() before it
# prints anything. log_helper() computes the colour-stripped strings only when
# a log file is open, then hands those NULL pointers to log_archdep(), which
# strlen()s them. `-logfile` does NOT save you — the banner runs first. The
# cure is that VICE's own log file must be openable, and VICE creates
# $HOME/.cache and $HOME/.config itself but NOT $HOME/.local/state. Every
# station hands the emulator a fresh per-station HOME, so every station walks
# into this unless the directory exists first.
export HOME="$BASE/home"
mkdir -p "$HOME/.local/state/vice"

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
# TWO-CANVAS MACHINES MUST CHOOSE. x128 has a VICII canvas and a VDC canvas and
# only one may publish; without this the VICII wins by refresh order even under
# -80col, which is measured, not feared (fork 507cf3e832). One-canvas stations
# leave it unset and the binary behaves exactly as before.
[ -n "${VICE_NATIVE_SHM_CHIP:-}" ] && export VICE_SHM_CHIP="$VICE_NATIVE_SHM_CHIP"
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
#
# VICE_NATIVE_ATTACH8 rides in the SAME block, between the undump and the `x`,
# and c128 is why it exists. A snapshot stores a drive's state but not its
# MEDIA, so a station whose exhibit has a disk in drive 8 has to put the image
# back — and the C128 cannot simply carry `-8 <d64>` on its command line,
# because its KERNAL boots any CP/M disk it finds in drive 8 AT RESET and this
# station's scene is the BASIC power-on screen. The bridged kiosk dodged that
# with a helper inside the guest that waited ~10 s and spoke the text monitor;
# here the attach happens at the READY breakpoint, which is already past the
# boot-sector check, synchronously, with nothing to race. A station whose disk
# does NOT autoboot (c64's GEOS) puts `-8 <image>` in VICE_NATIVE_ARGS instead
# and never needs this.
REST=()
if [ "${VICE_NATIVE_CHECKPOINT:-1}" = 1 ] && [ -f "$BASE/sta/golden.vsf" ]; then
  {
    printf 'undump "%s"\n' "$BASE/sta/golden.vsf"
    [ -n "${VICE_NATIVE_ATTACH8:-}" ] && printf 'attach "%s" 8\n' "$VICE_NATIVE_ATTACH8"
    printf 'x\n'
  } >"$BASE/sta/restore.mon"
  REST=(-moncommands "$BASE/sta/restore.mon" -initbreak ready)
fi

EXTRA=()
# shellcheck disable=SC2294 # the fixture value is a shell-quoted string on
# purpose, matching the MAME wave's MAME_NATIVE_ARGS.
[ -n "${VICE_NATIVE_ARGS:-}" ] && eval 'EXTRA=('"$VICE_NATIVE_ARGS"')'

# stdout is a file here, which is exactly the vice_banner() segfault condition
# above; the `mkdir -p "$HOME/.local/state/vice"` near the top is what makes it
# survive. Do not remove one without the other.
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
