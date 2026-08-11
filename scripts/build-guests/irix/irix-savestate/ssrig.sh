#!/usr/bin/env bash
# ssrig.sh — MAME savestate bake/restore rig for the IRIX station (issue #44).
#
# Runs a candidate `sgi` binary with the station's exact production flag set
# (shm capture, serial exec pty, no network) in a namespaced clone dir, then
# exercises the savestate cycle the exhibit needs:
#
#   ssrig.sh launch  <name> <binary> <cpus>        cold boot from the golden
#   ssrig.sh bake    <name> <state>                PAUSE + SAVEST + pair the CHD + RESUME
#   ssrig.sh restore <new> <binary> <cpus> <from> <state>
#                                                  paired CHD copy + `-state` relaunch (timed)
#   ssrig.sh shot    <name> [out.png]              screendump the shm framebuffer
#   ssrig.sh exec    <name> "<cmd>"                run a guest command over the serial agent
#   ssrig.sh probe   <name>                        does a MOVEP change the framebuffer?
#   ssrig.sh stop    <name>                        kill by pidfile via clone-guard
#
# State + pointer verbs go over the mamectl/1 socket the ctlsock OSD module
# binds at <dir>/ctl.sock (issue #45), so the binary under test must carry the
# module. Every verb is ACKED — SAVEST/LOADST on completion of the ~12 s
# stop-the-world immediate_save. Single-injector rule: MAME_CTL_SOCK set means
# NO -autoboot_script — the module and a Lua agent fight over pacing
# budgets/accumulators.
#
# The bake is atomic by construction: the guest is PAUSED across the state save
# and the CHD reflink copy, so the (memory, disk) pair cannot diverge — the
# same invariant the CRIU procedure takes a ZFS snapshot inside the freeze
# window for. A mismatched pair is invisible to every after-the-fact check
# (see irix-criu/README.md), so it is prevented, never detected.
set -u

SS_ROOT="${SS_ROOT:-/data/vms/soltest/irix-ss44}"
case "$SS_ROOT" in
  /data/vms/soltest/*) : ;;
  *)
    echo "refusing to work outside /data/vms/soltest" >&2
    exit 1
    ;;
esac
A="${IRIX_ASSETS:-/data/vms/streamhost/assets/irix}"
GOLDEN="${GOLDEN:-$A/irix65-apps-v9.chd}"
CG="${CLONE_GUARD:-/usr/local/bin/clone-guard}"
RIG="$(cd -- "$(dirname -- "$0")" && pwd)"
IEX="${IRIX_EXEC:-/root/irixexec.py}"
SHMPNG="${IRIX_SHMPNG:-$RIG/../irix-bench/shmpng.py}"
[ -f "$SHMPNG" ] || SHMPNG="$RIG/shmpng.py" # box deploy keeps a copy beside the rig
# mamectl/1 client: prefer the promoted production mctl.py (beside irixexec.py
# / the deployed rig), else the repo's mctl-probe.py.
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

say() { printf '%s %s\n' "$(date +%T)" "$*"; }
die() {
  echo "FATAL: $*" >&2
  exit 1
}

mctl() { # $1 = rig dir, rest = the verb line
  [ -n "$MCTL" ] || die "no mamectl client found — deploy mctl.py beside this rig or set IRIX_MCTL"
  python3 "$MCTL" "$1/ctl.sock" --timeout 120 "${@:2}"
}

launch_mame() { # $1=dir $2=binary $3=cpus [$4=state-name]
  local d="$1" bin="$2" cpus="$3" st="${4:-}" starg=() p
  [ -f "$d/disk.chd" ] || die "no disk.chd in $d"
  : >"$d/serial.lock"
  rm -f -- "$d/fb.shm" "$d/ctl.sock"
  [ -n "$st" ] && starg=(-state "$st")
  env -u DISPLAY -u SDL_VIDEODRIVER \
    IRIX_SHM_PATH="$d/fb.shm" \
    MAME_CTL_SOCK="$d/ctl.sock" \
    MAME_CTL_CURSOR_ITEMS=":vc2/0/m_cursor_x,:vc2/0/m_cursor_y,:vc2/0/m_enable_cursor" \
    nohup taskset -c "$cpus" \
    "$A/glibc/ld-linux-x86-64.so.2" \
    --library-path "$A/glibc:/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu" \
    "$bin" indy_4610 -bios b10 -rompath "$A/roms" -gio64_gfx xl24 \
    -hard1 "$d/disk.chd" \
    -ioc2:rs232a pty \
    -nvram_directory "$d/nvram" -inipath "$A/uicfg" \
    -skip_gameinfo -video none -sound none \
    -frameskip "${IRIX_FRAMESKIP:-6}" \
    -state_directory "$d/sta" \
    "${starg[@]}" \
    >"$d/mame.log" 2>&1 &
  p=$!
  echo "$p" >"$d/mame.pid"
  sleep 4
  [ -e "/proc/$p" ] || {
    tail -20 "$d/mame.log" >&2
    die "MAME died at launch"
  }
  # ctlsock binds at OSD init, well before the guest boots — a missing socket
  # here means a binary without the module, which this rig cannot drive.
  for _ in $(seq 12); do
    [ -S "$d/ctl.sock" ] && break
    sleep 5
  done
  [ -S "$d/ctl.sock" ] || die "no $d/ctl.sock after 60s — binary lacks the ctlsock module"
  say "mame up pid=$p dir=$d${st:+ state=$st} ctl=$d/ctl.sock"
}

cmd="${1:?subcommand}"
shift
case "$cmd" in
  launch)
    N="${1:?name}" BIN="${2:?binary}" CPUS="${3:?cpus}"
    D="$SS_ROOT/$N"
    pgrep -f "$D/disk.chd" >/dev/null && die "something already runs on $D/disk.chd"
    rm -rf "$D"
    mkdir -p "$D/nvram" "$D/sta"
    cp --reflink=always -- "$GOLDEN" "$D/disk.chd"
    chmod 644 -- "$D/disk.chd"
    cp -r "$A/nvram/." "$D/nvram/"
    {
      md5sum "$BIN"
      md5sum "$GOLDEN"
    } >"$D/provenance.md5"
    launch_mame "$D" "$BIN" "$CPUS"
    ;;
  bake)
    N="${1:?name}" ST="${2:?state name}"
    D="$SS_ROOT/$N"
    [ -f "$D/mame.pid" ] && [ -e "/proc/$(cat "$D/mame.pid")" ] || die "no live MAME in $D"
    say "pausing"
    mctl "$D" PAUSE || die "PAUSE not acknowledged"
    # SAVEST while RUNNING can ERR busy (pending anonymous timers) — PAUSE
    # first, always. The ack lands on completion of the immediate_save.
    say "saving state '$ST' (ack = completion, ~12s stop-the-world)"
    mctl "$D" SAVEST "$ST" || die "SAVEST $ST failed"
    stf="$D/sta/indy_4610/$ST.sta"
    [ -s "$stf" ] || {
      tail -5 "$D/mame.log" >&2
      die "SAVEST acked but $stf is missing"
    }
    say "state: $stf ($(du -h "$stf" | cut -f1)) — pairing the CHD inside the pause window"
    cp --reflink=always -- "$D/disk.chd" "$D/disk-$ST.chd"
    md5sum "$stf" "$D/disk-$ST.chd" >"$D/pair-$ST.md5"
    mctl "$D" RESUME || die "RESUME not acknowledged"
    say "bake done: $D/sta + $D/disk-$ST.chd (pair-$ST.md5)"
    ;;
  restore)
    N="${1:?new name}" BIN="${2:?binary}" CPUS="${3:?cpus}" FROM="${4:?bake rig name}" ST="${5:?state name}"
    S="$SS_ROOT/$FROM"
    D="$SS_ROOT/$N"
    [ -f "$S/disk-$ST.chd" ] || die "no paired disk $S/disk-$ST.chd"
    pgrep -f "$D/disk.chd" >/dev/null && die "something already runs on $D/disk.chd"
    rm -rf "$D"
    mkdir -p "$D/nvram" "$D/sta"
    t0=$(date +%s.%N)
    cp --reflink=always -- "$S/disk-$ST.chd" "$D/disk.chd"
    chmod 644 -- "$D/disk.chd"
    cp -r "$A/nvram/." "$D/nvram/"
    cp -r "$S/sta/." "$D/sta/"
    launch_mame "$D" "$BIN" "$CPUS" "$ST"
    # Stop the clock only on evidence: a published frame in the shm.
    for _ in $(seq 600); do
      [ -s "$D/fb.shm" ] && python3 "$SHMPNG" "$D/fb.shm" "$D/restore-first-frame.png" 2>/dev/null && break
      sleep 0.5
    done
    t1=$(date +%s.%N)
    say "restore wall (launch -> first published frame): $(echo "$t1 $t0" | awk '{printf "%.1fs", $1-$2}')"
    say "check the log for the state load verdict:"
    grep -i "state\|error" "$D/mame.log" | tail -5 || true
    ;;
  shot)
    N="${1:?name}"
    OUT="${2:-$SS_ROOT/$1/shot-$(date +%H%M%S).png}"
    python3 "$SHMPNG" "$SS_ROOT/$N/fb.shm" "$OUT" && echo "$OUT"
    ;;
  exec)
    N="${1:?name}" C="${2:?cmd}"
    python3 "$IEX" "$SS_ROOT/$N" "$C" --timeout "${SS_EXEC_TIMEOUT:-25}"
    ;;
  probe)
    N="${1:?name}"
    D="$SS_ROOT/$N"
    python3 "$SHMPNG" "$D/fb.shm" "$D/probe-a.png" || die "no frame"
    mctl "$D" MOVEP 60 60 || die "MOVEP not acknowledged"
    sleep 2
    python3 "$SHMPNG" "$D/fb.shm" "$D/probe-b.png" || die "no frame"
    if cmp -s "$D/probe-a.png" "$D/probe-b.png"; then
      echo "PROBE: framebuffer DID NOT change after MOVEP" >&2
      exit 1
    fi
    echo "PROBE: framebuffer changed after MOVEP (pointer alive)"
    ;;
  stop)
    N="${1:?name}"
    "$CG" kill-pidfile "$SS_ROOT/$N/mame.pid"
    sleep 1
    pgrep -f "$SS_ROOT/$N/disk.chd" >/dev/null && die "MAME survived the stop"
    say "stopped, clean"
    ;;
  *)
    die "unknown subcommand: $cmd"
    ;;
esac
