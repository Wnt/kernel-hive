#!/usr/bin/env bash
# bake-golden.sh — bake the IRIX station's instant-restore state (issue #44).
#
# Boots the PRODUCTION configuration (the station's own launcher, tile.env, golden
# and tap networking) in a namespaced clone, waits for the exhibit's resting
# state (the login chooser, or — with --login — a logged-in 4Dwm desktop), then
# captures the (savestate, disk) pair ATOMICALLY
# inside a pause window and installs it under $ASSETS/state/ with a provenance
# file binding it to the exact MAME binary. x11-runtime.sh refuses to restore a
# state whose provenance does not list the running binary's md5 — a MAME rebuild
# orphans every state (registration-signature change), so REBAKE AFTER EVERY
# MAME PROMOTION: stop the station, run this, start the station.
#
#   bake-golden.sh [--state NAME] [--cpus LIST] [--settle S] [--keep]
#                  [--login USER] [--login-wait S]
#
# --login USER types USER into the iconlogin chooser (one character per tick —
# the Login-name widget drops fast natkeyboard input) plus Enter, waits
# --login-wait seconds for the session to paint, and REQUIRES the 4Dwm Toolchest
# on the real framebuffer before saving. The exhibit then restores straight into
# that user's desktop instead of the chooser. Accounts with a password cannot be
# baked this way (nothing types one); `demos` is passwordless in the golden.
#
# Run ON the box, with streamhost@irix STOPPED (it refuses otherwise).
set -u

STATE=golden
CPUS=6,14
SETTLE=120
KEEP=0
LOGIN=""
LOGIN_WAIT=50
# Content-based desktop test, from irix-park-desktop.sh: full-frame statistics
# cannot separate "logged in, bare X root" (toolchest-crop sd 0.095) from
# "logged in, 4Dwm up" (0.257), so crop the Toolchest and require contrast.
TOOLCHEST_CROP=130x230+0+30
TOOLCHEST_SD_MIN=0.18
while [ $# -gt 0 ]; do
  case "$1" in
    --login)
      LOGIN="$2"
      shift 2
      ;;
    --login-wait)
      LOGIN_WAIT="$2"
      shift 2
      ;;
    --state)
      STATE="$2"
      shift 2
      ;;
    --cpus)
      CPUS="$2"
      shift 2
      ;;
    --settle)
      SETTLE="$2"
      shift 2
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

T="${IRIX_TILE_DIR:-/data/vms/streamhost/tiles/irix}"
A="${IRIX_ASSETS:-/data/vms/streamhost/assets/irix}"
CG="${CLONE_GUARD:-/usr/local/bin/clone-guard}"
RIG="$(cd -- "$(dirname -- "$0")" && pwd)"
SHMPNG="${IRIX_SHMPNG:-$RIG/shmpng.py}"
[ -f "$SHMPNG" ] || SHMPNG="$RIG/../irix-bench/shmpng.py"
# mamectl/1 client (issue #45): prefer the promoted production mctl.py (beside
# irixexec.py / the deployed rig), else the repo's mctl-probe.py so a bare
# checkout still bakes.
MCTL="${IRIX_MCTL:-}"
if [ -z "$MCTL" ]; then
  for c in "$RIG/mctl.py" /root/mctl.py \
    "$RIG/../../../../streamhost/guest-agents/irix/mctl.py" \
    "$RIG/mctl-probe.py" "$RIG/../irix-ctl/mctl-probe.py"; do
    if [ -f "$c" ]; then
      MCTL="$c"
      break
    fi
  done
fi
V="${IRIX_BAKE_DIR:-/data/vms/soltest/irix-ss-bake-$$}"
case "$V" in
  /data/vms/soltest/*) : ;;
  *)
    echo "refusing to work outside /data/vms/soltest" >&2
    exit 1
    ;;
esac

say() { printf '%s %s\n' "$(date +%T)" "$*"; }
die() {
  echo "FATAL: $*" >&2
  exit 1
}

# Teardown runs on EVERY exit, success or failure — a paused MAME left behind
# by a failed bake blocks the next one and squats a core. Idempotent: pidfiles
# are truncated by the killers, and a cleaned-up $V simply has nothing to kill.
teardown() {
  [ -d "$V" ] || return 0
  "$CG" kill-pidfile "$V/mame.pid" >/dev/null 2>&1 || true
  for w in bootwatch livewatch; do
    [ -f "$V/$w.pid" ] && kill "$(cat "$V/$w.pid")" 2>/dev/null
    : >"$V/$w.pid" 2>/dev/null || true
  done
}
trap teardown EXIT

systemctl is-active --quiet streamhost@irix.service && die "streamhost@irix is running — stop it first"
[ -n "$MCTL" ] || die "no mamectl client found — deploy mctl.py beside this rig or set IRIX_MCTL"

rm -rf "$V"
mkdir -p "$V"
cp "$T/x11-runtime.sh" "$T/fbstat.py" "$T/tapnet.sh" "$V/"
"$CG" check-launcher "$V/x11-runtime.sh" || exit 1
# The launcher's Lua-rollback arm runs $D/irixagent.lua; the mamectl arm this
# bake requires ignores it (single-injector rule: ctl socket set => no
# autoboot Lua).
cp "$T/irixagent.lua" "$V/"

say "launching the production configuration in $V (cold boot, ~7 min)"
(
  # cd first: the production launcher passes no -state_directory on a cold
  # boot, so SAVEST writes to MAME's cwd-relative default "sta/" — which must
  # be $V/sta, not wherever this script happened to be invoked from.
  cd "$V" || exit 1
  while IFS= read -r line; do
    case "$line" in '#'* | '') continue ;; esac
    export "${line%%=*}=${line#*=}"
  done <"$T/tile.env"
  export IRIX_CPUS="$CPUS" IRIX_WATCH_UNIT="" IRIX_STATE=""
  # Namespace EVERY producer path into the clone dir — tile.env's values point
  # at the live station tree (the audio fifo included, since the audio arm).
  export SH_SHM_PATH="$V/fb.shm" SH_X11_CMD_FILE="$V/irix_cmd"
  export SH_AUDIO_FIFO="$V/audio.fifo"
  bash "$V/x11-runtime.sh" >"$V/launch.log" 2>&1
) || {
  cat "$V/launch.log" >&2
  die "launch failed"
}
# The binary the launcher used: a tile.env IRIX_MAME pin, else the default.
MAME_BIN="$(grep '^IRIX_MAME=' "$T/tile.env" | tail -1 | cut -d= -f2)"
MAME_BIN="${MAME_BIN:-$A/mame/sgi}"
touch "$V/serial.lock"

# The mamectl socket binds at OSD init, minutes before IRIX finishes booting;
# absent by now means the launcher took the IRIX_CTL=off (Lua agent) arm,
# which has no acked PAUSE/SAVEST left for this bake to drive.
for _ in $(seq 24); do
  [ -S "$V/ctl.sock" ] && break
  sleep 5
done
[ -S "$V/ctl.sock" ] ||
  die "no $V/ctl.sock after 120s — a launcher running IRIX_CTL=off cannot bake; enable the mamectl socket arm"
mctl() { python3 "$MCTL" "$V/ctl.sock" --timeout 120 "$@"; }

# Boot-to-chooser is ~65 s measured on an idle box; the old wait-until-300s
# schedule was the measurement artifact that kept "~340 s boot" alive in
# every report. Sampling starts at 55 s and the break needs 3 CONSECUTIVE
# stable non-black means: the t>=55 floor clears the PROM-splash band
# (t~10-30), and stability rejects mid-transition boot frames.
say "waiting for the chooser (sampling from 55s, 3 stable hits)"
t0=$(date +%s)
hits=0
prev=-1
while :; do
  sleep 5
  p="$(cat "$V/mame.pid" 2>/dev/null)"
  [ -n "$p" ] && [ -e "/proc/$p" ] || die "MAME died during boot (see $V/mame.log)"
  el=$(($(date +%s) - t0))
  if [ "$el" -ge 55 ]; then
    if python3 "$SHMPNG" "$V/fb.shm" "$V/boot.png" >/dev/null 2>&1; then
      m="$(identify -format '%[mean]' "$V/boot.png" 2>/dev/null | cut -d. -f1)"
      d=$((${m:-0} - prev))
      if [ "${m:-0}" -gt 1500 ] && [ "${d#-}" -le 30 ]; then
        hits=$((hits + 1))
        [ "$hits" -ge 3 ] && break
      else
        hits=0
      fi
      prev="${m:-0}"
    fi
  fi
  [ "$el" -gt 1500 ] && die "no desktop after ${el}s"
done
say "chooser up at t=$(($(date +%s) - t0))s; settling ${SETTLE}s"
sleep "$SETTLE"

# Typing into the chooser before the machine has finished coming up panics IRIX
# (PANIC: bad istack, deterministic) — the $SETTLE floor above is that guard,
# so the login goes AFTER it, never on a shorter timer of its own.
if [ -n "$LOGIN" ]; then
  say "logging in as '$LOGIN' (one char per tick; the widget drops fast input)"
  i=0
  while [ "$i" -lt "${#LOGIN}" ]; do
    ch="${LOGIN:$i:1}"
    i=$((i + 1))
    mctl POST "$ch" >/dev/null || die "POST '$ch' not acknowledged"
    sleep 0.8
  done
  sleep 2
  mctl CODE '{ENTER}' >/dev/null || die "CODE {ENTER} not acknowledged"
  say "waiting ${LOGIN_WAIT}s for the session to paint"
  sleep "$LOGIN_WAIT"
  python3 "$SHMPNG" "$V/fb.shm" "$V/login.png" >/dev/null 2>&1 ||
    die "no frame after login (see $V/mame.log)"
  convert "$V/login.png" -crop "$TOOLCHEST_CROP" +repage "$V/tc.png" ||
    die "could not crop the Toolchest region out of $V/login.png"
  tcsd="$(identify -format '%[fx:standard_deviation]' "$V/tc.png" 2>/dev/null)"
  awk -v s="${tcsd:-0}" -v m="$TOOLCHEST_SD_MIN" 'BEGIN { exit !(s > m) }' ||
    die "no 4Dwm Toolchest ${LOGIN_WAIT}s after login (crop sd=${tcsd:-none}, need >$TOOLCHEST_SD_MIN) — look at $V/login.png"
  say "desktop confirmed for '$LOGIN' (toolchest-crop sd=$tcsd)"
fi

say "pausing + saving state '$STATE' (acked over ctl.sock)"
mctl PAUSE || die "PAUSE not acknowledged"
# SAVEST while RUNNING can ERR busy (pending anonymous timers) — PAUSE first,
# always. The ack lands on COMPLETION of the ~12 s stop-the-world
# immediate_save (it replaced a state-file size-stability grep loop).
mctl SAVEST "$STATE" || die "SAVEST $STATE failed"
STA="$V/sta/indy_4610/$STATE.sta"
[ -s "$STA" ] || die "SAVEST acked but $STA is missing"
say "state written ($(du -h "$STA" | cut -f1)); pairing the disk inside the pause window"
cp --reflink=always -- "$V/disk.chd" "$V/disk-$STATE.chd"

say "installing to $A/state/"
mkdir -p "$A/state/sta/indy_4610"
install -m 444 "$STA" "$A/state/sta/indy_4610/$STATE.sta"
rm -f "$A/state/disk-$STATE.chd"
cp --reflink=always -- "$V/disk-$STATE.chd" "$A/state/disk-$STATE.chd"
chmod 444 "$A/state/disk-$STATE.chd"
{
  md5sum "$MAME_BIN"
  md5sum "$A/state/sta/indy_4610/$STATE.sta"
  md5sum "$A/state/disk-$STATE.chd"
} >"$A/state/provenance-$STATE.md5"
say "provenance:"
cat "$A/state/provenance-$STATE.md5"

# Teardown is part of done — kill by pidfile, watchdogs included, and verify.
"$CG" kill-pidfile "$V/mame.pid"
for w in bootwatch livewatch; do
  pf="$V/$w.pid"
  [ -f "$pf" ] && kill "$(cat "$pf")" 2>/dev/null
done
sleep 2
pgrep -f "$V/disk.chd" >/dev/null && die "MAME survived the stop"
[ "$KEEP" = 1 ] || rm -rf "$V"
say "baked: IRIX_STATE=$STATE is ready (tile.env enables it); teardown verified clean"
