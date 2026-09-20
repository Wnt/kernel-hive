#!/bin/bash
# =============================================================================
# stations/multics/x11-runtime.sh — launcher for the Multics station, CONTAINED.
# Started by ensure-station-x11.sh inside the streamhost@multics BindsTo scope.
#
# Multics MR12.8 (Honeywell/Bull, the last release, 1992) on an emulated
# DPS-8/M under the DPS8M simulator R3.1.0 (dps8m.gitlab.io, pinned in
# assets/multics/MANIFEST.sha256). No QEMU, no MAME, no checkpoint: the exhibit
# is a simulator process plus one terminal, and reset = relaunch from the
# pristine baked root.dsk — MEASURED 1.35 s to reflink-copy the 594 MB RPV on
# labhost's ZFS with the box at load 60 (0.126 s on an idle box), which is why
# this station wants relaunch and not a golden.
#
# CONTAINMENT (docs/lab/record-wave/HOST-APP-CONTAINER-CONTRACT.md, the proven
# medley/vision/lisa/perq shape): DPS8M, Xvfb and the visitor's xterm all run
# inside a systemd-nspawn container — own PID/mount/IPC/UTS/user namespaces,
# --private-users so root inside is host uid MULTICS_UIDBASE, --private-network
# so the FNP telnet line is reachable only from inside, --volatile=overlay
# throwaway root over a minimal Debian tree, bin/ and media/ bound READ-ONLY at
# their host paths, work/ the only writable bind, CAP_SYS_ADMIN & friends
# dropped, mount syscalls filtered, no-new-privileges. The visitor logs in to
# Multics as a real user with a known password, so the containment, not the
# guest, is the security boundary.
#
# The X socket lives in a host directory bound over the container's
# /tmp/.X11-unix, with /tmp/.X11-unix/X<n> on the host a symlink to it, so
# capture (SH_CAPTURE=x11), XTEST input, `labctl shot` and xdotool are unchanged.
#
# Pidfile contract (ensure-station-x11.sh / stop-station-x11.sh, idle.rs):
#   mame.pid   the DPS8M `dps8` HOST-visible pid — the daemon SIGSTOP/SIGCONTs it
#   xvfb.pid   the container's Xvfb, host pid
#   nspawn.pid the systemd-nspawn supervisor (reaped so no container lingers)
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${MULTICS_BASE:-/data/vms/streamhost/stations/$TILE}"
ASSETS="${MULTICS_ASSETS:-/data/vms/streamhost/assets/$TILE}"
GEOM="${MULTICS_GEOM:-1024x768}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
PORT="${MULTICS_PORT:-6180}"
ROOTFS="${MULTICS_ROOTFS:-$ASSETS/rootfs}"
UIDBASE="${MULTICS_UIDBASE:-2555904}"
SOCKDIR="${MULTICS_X11_SOCKDIR:-/run/streamhost/x11/$TILE}"
SEED="${MULTICS_SEED_DISK:-$ASSETS/media/root.dsk}"
BIN="$ASSETS/bin/dps8"
HERE="$(dirname "$(readlink -f "$0")")"
INNER="$HERE/nspawn-inner.sh"
TERMBR="$HERE/multics-term.pl"
SHARED="$HERE/shared-terminal-runtime.sh"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name, not a MAME claim
XPIDFILE="$BASE/xvfb.pid"
NPIDFILE="$BASE/nspawn.pid"
XSOCK="/tmp/.X11-unix/X${DISP#:}"

[ -x "$BIN" ] || {
  echo "multics[$TILE]: no DPS8M simulator at $BIN" >&2
  exit 1
}
[ -f "$SEED" ] || {
  echo "multics[$TILE]: no baked RPV at $SEED" >&2
  exit 1
}
[ -f "$ASSETS/media/12.8MULTICS.tap" ] || {
  echo "multics[$TILE]: no MR12.8 system tape at $ASSETS/media/12.8MULTICS.tap" >&2
  exit 1
}
[ -x "$ROOTFS/usr/bin/xterm" ] || {
  echo "multics[$TILE]: no container rootfs at $ROOTFS" >&2
  exit 1
}
for f in "$INNER" "$SHARED" "$TERMBR"; do
  [ -f "$f" ] || {
    echo "multics[$TILE]: missing $f" >&2
    exit 1
  }
done

# --- reap: the simulator by exe (scoped to this station's asset dir, which is
# bound at its host path inside the container so /proc/<pid>/exe agrees), then
# any supervisor left over. SIGCONT before TERM — a SIGSTOPped simulator never
# handles TERM. Refuse to start over a survivor.
#
# Resolve by /proc/<pid>/exe (AGENTS.md rule 5 — never a cmdline grep), but in
# ONE fork instead of one `readlink` per pid. MEASURED 2026-09-20 on a loaded
# box: the per-pid loop cost 13.4 s per scan at 1322 PIDs, the launcher calls it
# once to reap and once per wait iteration, and the unit's 90 s start-pre
# timeout then killed every restart. `find -lname` matches the same symlink
# target, including a "... (deleted)" exe, in ~0.05 s.
station_vm_pids() {
  find /proc -mindepth 2 -maxdepth 2 -name exe -lname "$ASSETS/bin/*" \
    -printf '%h\n' 2>/dev/null |
    sed 's#^/proc/##' |
    grep -E '^[0-9]+$' |
    grep -vx "$$" || true
}
pidfile_alive() { # $1 pidfile $2 expected exe basename
  local p exe
  p="$(cat "$1" 2>/dev/null || true)"
  case "$p" in '' | *[!0-9]*) return 1 ;; esac
  exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || return 1
  [ "$(basename "${exe% (deleted)}")" = "$2" ] && printf '%s\n' "$p"
}
reap_previous() {
  local p
  for p in $(station_vm_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  for _ in $(seq 1 40); do
    [ -z "$(station_vm_pids)" ] && break
    sleep 0.25
  done
  for p in $(station_vm_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null || true
  done
  if p="$(pidfile_alive "$NPIDFILE" systemd-nspawn)"; then
    for _ in $(seq 1 20); do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.25
    done
    kill -0 "$p" 2>/dev/null && kill -TERM "$p" 2>/dev/null || true
  fi
  sleep 0.5
  [ -z "$(station_vm_pids)" ]
}

reap_previous || {
  echo "multics[$TILE]: previous simulator still alive after SIGKILL:" \
    "$(station_vm_pids | tr '\n' ' ')— refusing to start a second one" >&2
  exit 1
}
rm -f "$PIDFILE" "$XPIDFILE" "$NPIDFILE"

# --- host side of the X socket dir, owned by the container's root.
mkdir -p "$SOCKDIR"
chown "$UIDBASE:$UIDBASE" "$SOCKDIR"
chmod 1777 "$SOCKDIR"
rm -f "$SOCKDIR/X${DISP#:}"
if [ -e "$XSOCK" ] && [ ! -L "$XSOCK" ]; then
  echo "multics[$TILE]: $XSOCK exists and is not our symlink — display $DISP is someone else's" >&2
  exit 1
fi
mkdir -p /tmp/.X11-unix
ln -sfn "$SOCKDIR/X${DISP#:}" "$XSOCK"

# --- pristine per-launch state. work/ is the only writable bind and holds the
# ONLY disk the simulator ever attaches; the seed in media/ is mode 0444 and
# bound read-only. THE SEED MUST HAVE BEEN BAKED FROM A GUEST THAT REACHED
# `shutdown complete` at the operator console — that line is Multics' own
# statement that every page has been flushed to the RPV. A simulator killed
# mid-run leaves the RPV inconsistent and the next boot stops in BCE asking
# questions no autoinput sheet answers, which from outside looks exactly like a
# station that never boots.
#
# `cp --reflink=auto` is the point of this whole design: MEASURED 1.35 s for
# the 594 MB RPV on labhost's ZFS under load (0.126 s idle), so a pristine copy
# per launch is free and the station needs no checkpoint at all.
rm -rf "$BASE/work"
mkdir -p "$BASE/work"
cp --reflink=auto "$SEED" "$BASE/work/root.dsk"
chown -R "$UIDBASE:$UIDBASE" "$BASE/work"
chmod 0644 "$BASE/work/root.dsk"
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$INNER" "$BASE/work/nspawn-inner.sh"
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$SHARED" "$BASE/work/shared-terminal-runtime.sh"
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$TERMBR" "$BASE/work/multics-term.pl"

nohup systemd-nspawn \
  --quiet --register=no --keep-unit --as-pid2 \
  --machine="kh-$TILE" --uuid="$(printf '%032x' "$UIDBASE")" \
  --directory="$ROOTFS" --volatile=overlay \
  --private-users="$UIDBASE:65536" --private-users-ownership=off \
  --private-network \
  --drop-capability=CAP_SYS_ADMIN,CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE \
  --no-new-privileges=yes \
  --system-call-filter='~@mount' \
  --bind-ro="$ASSETS/bin" \
  --bind-ro="$ASSETS/media" \
  --bind="$BASE/work:/work" \
  --bind="$SOCKDIR:/tmp/.X11-unix" \
  --setenv=SH_X11_DISPLAY="$DISP" \
  --setenv=MULTICS_ASSETS="$ASSETS" \
  --setenv=MULTICS_GEOM="$GEOM" \
  --setenv=MULTICS_READY_TIMEOUT_S="${MULTICS_READY_TIMEOUT_S:-420}" \
  --setenv=MULTICS_PORT="$PORT" \
  --setenv=MULTICS_COLS="${MULTICS_COLS:-80}" \
  --setenv=MULTICS_ROWS="${MULTICS_ROWS:-24}" \
  --setenv=MULTICS_FONTSIZE="${MULTICS_FONTSIZE:-14}" \
  --setenv=MULTICS_XOFF="${MULTICS_XOFF:-+32+96}" \
  --setenv=HOME=/work --setenv=TERM=vt100 \
  --kill-signal=SIGTERM --console=pipe \
  /work/nspawn-inner.sh \
  >"$BASE/multics.log" 2>&1 </dev/null &
echo $! >"$NPIDFILE"

# Multics reaches its answering service in ~52 s from a clean RPV (MEASURED
# 2026-09-20T08:58:32Z: TCP/6180 open at +4 s, `as_init_: Multics MR12.8;
# Answering Service 17.0` at +52 s — the 48 s gap is finding 1 of the shared
# runtime, and why the readiness gate is a console line and not a port probe).
# Wait on the real things: the simulator pid, the X socket, and the visitor
# window actually mapped — never on a guessed sleep.
SPID=""
for _ in $(seq 1 "${MULTICS_LAUNCH_TIMEOUT_S:-360}"); do
  kill -0 "$(cat "$NPIDFILE")" 2>/dev/null || {
    echo "multics[$TILE]: container died at launch — tail of multics.log:" >&2
    tail -40 "$BASE/multics.log" >&2
    exit 1
  }
  SPID="$(station_vm_pids | head -1)"
  if [ -n "$SPID" ] && [ -S "$SOCKDIR/X${DISP#:}" ] &&
    xwininfo -root -tree -display "$DISP" 2>/dev/null | grep -q "Multics console"; then
    break
  fi
  SPID=""
  sleep 1
done
[ -n "$SPID" ] || {
  echo "multics[$TILE]: no Multics terminal window — tail of multics.log:" >&2
  tail -40 "$BASE/multics.log" >&2
  tail -40 "$BASE/work/emulator.log" 2>/dev/null >&2 || true
  exit 1
}

# --- focus, then wait for the Multics banner to be ON THE FRAMEBUFFER.
#
# No window manager runs in the container, so X input focus is PointerRoot and
# keystrokes reach the xterm only while the pointer happens to be over it. The
# daemon drives this station with XTEST keys and never moves a pointer (there
# is none in the exhibit), so without an explicit XSetInputFocus a visitor's
# typing would land on the root window and vanish. `xdotool windowfocus` pins
# it once, for good. (Finding inherited from vax43bsd, which paid for it.)
#
# Nothing is TYPED here. The station's own bridge (multics-term.pl) answers the
# FNP's channel menu itself, so the launcher's job is only to confirm that the
# banner really arrived — a station that starts with a mapped but empty xterm
# is exactly how a black exhibit gets onto the wall. The gate is a settled
# lit-pixel count over a floor: after the bridge clears the plumbing the whole
# scene is two lines and a cursor, so the floor is deliberately low and the
# SETTLING is what carries the proof.
export DISPLAY="$DISP"
nlit() {
  xwd -display "$DISP" -root -silent 2>/dev/null |
    convert xwd:- -colorspace Gray -threshold 25% -format '%[fx:int(mean*w*h)]' info: 2>/dev/null || echo 0
}
WIN="$(xdotool search --name 'Multics console' 2>/dev/null | head -1 || true)"
if [ -n "$WIN" ]; then
  xdotool windowfocus "$WIN" 2>/dev/null || true
  lit=0
  prev=-1
  same=0
  for _ in $(seq 1 "${MULTICS_BANNER_TRIES:-120}"); do
    sleep 0.5
    lit="$(nlit)"
    if [ "$lit" -ge "${MULTICS_BANNER_LIT_PX:-400}" ] && [ "$lit" = "$prev" ]; then
      same=$((same + 1))
      [ "$same" -ge 4 ] && break
    else
      same=0
    fi
    prev="$lit"
  done
  if [ "$lit" -ge "${MULTICS_BANNER_LIT_PX:-400}" ]; then
    echo "multics[$TILE]: Multics banner on the framebuffer ($lit lit px, settled)"
  else
    echo "multics[$TILE]: WARNING — no Multics banner (lit px $lit, wanted" \
      "${MULTICS_BANNER_LIT_PX:-400}); the rest scene may open black" >&2
  fi
fi

echo "$SPID" >"$PIDFILE"
XV=""
for d in /proc/[0-9]*; do
  p="${d#/proc/}"
  [ "$(readlink "/proc/$p/ns/pid" 2>/dev/null)" = "$(readlink "/proc/$SPID/ns/pid" 2>/dev/null)" ] || continue
  case "$(readlink "/proc/$p/exe" 2>/dev/null)" in */Xvfb) XV="$p" ;; esac
done
[ -n "$XV" ] && echo "$XV" >"$XPIDFILE"
echo "multics[$TILE]: dps8=$SPID xvfb=${XV:-?} nspawn=$(cat "$NPIDFILE") display=$DISP geom=$GEOM fnp=$PORT uidbase=$UIDBASE (contained relaunch from the pristine baked RPV)"

# Standby: freeze the simulator once the login prompt has settled; the daemon
# owns the steady state via SH_IDLE_PAUSE_PIDFILE and SIGCONTs on the first
# session. A frozen DPS-8/M costs no core between visitors.
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${MULTICS_STANDBY_DELAY_S:-30}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = "$BIN" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "multics[$TILE]: standby — frozen at the Multics login (pid $p; first session wakes it)"
  ) &
fi
