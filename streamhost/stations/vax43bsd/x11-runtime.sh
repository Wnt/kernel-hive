#!/bin/bash
# =============================================================================
# stations/vax43bsd/x11-runtime.sh — launcher for the 4.3BSD station, CONTAINED.
# Started by ensure-station-x11.sh inside the streamhost@vax43bsd BindsTo scope.
#
# 4.3BSD (Berkeley, June 1986) on an emulated DEC VAX-11/780 under Open SIMH
# (github.com/open-simh/simh, pinned in assets/vax43bsd/MANIFEST.sha256). No
# QEMU, no MAME, no checkpoint: the exhibit is a simulator process plus one
# terminal, and reset = relaunch from the pristine seed RA81.
#
# CONTAINMENT (docs/lab/record-wave/HOST-APP-CONTAINER-CONTRACT.md, the proven
# medley/vision/lisa/perq shape): SIMH, Xvfb and the visitor's xterm all run
# inside a systemd-nspawn container — own PID/mount/IPC/UTS/user namespaces,
# --private-users so root inside is host uid VAX43BSD_UIDBASE, --private-network
# so the DZ11 telnet line is reachable only from inside, --volatile=overlay
# throwaway root over a minimal Debian tree, bin/ and media/ bound READ-ONLY at
# their host paths, work/ the only writable bind, CAP_SYS_ADMIN & friends
# dropped, mount syscalls filtered, no-new-privileges. 4.3BSD's root account has
# no password — that is stock 1986 — so the containment, not the guest, is the
# security boundary.
#
# The X socket lives in a host directory bound over the container's
# /tmp/.X11-unix, with /tmp/.X11-unix/X<n> on the host a symlink to it, so
# capture (SH_CAPTURE=x11), XTEST input, `labctl shot` and xdotool are unchanged.
#
# Pidfile contract (ensure-station-x11.sh / stop-station-x11.sh, idle.rs):
#   mame.pid   the SIMH vax780 HOST-visible pid — the daemon SIGSTOP/SIGCONTs it
#   xvfb.pid   the container's Xvfb, host pid
#   nspawn.pid the systemd-nspawn supervisor (reaped so no container lingers)
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${VAX43BSD_BASE:-/data/vms/streamhost/stations/$TILE}"
ASSETS="${VAX43BSD_ASSETS:-/data/vms/streamhost/assets/$TILE}"
GEOM="${VAX43BSD_GEOM:-1024x768}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
PORT="${VAX43BSD_PORT:-10023}"
ROOTFS="${VAX43BSD_ROOTFS:-$ASSETS/rootfs}"
UIDBASE="${VAX43BSD_UIDBASE:-2490368}"
SOCKDIR="${VAX43BSD_X11_SOCKDIR:-/run/streamhost/x11/$TILE}"
SEED="${VAX43BSD_SEED_DISK:-$ASSETS/media/bsd43-ra81.dsk}"
BIN="$ASSETS/bin/vax780"
HERE="$(dirname "$(readlink -f "$0")")"
INNER="$HERE/nspawn-inner.sh"
SHARED="$HERE/shared-terminal-runtime.sh"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name, not a MAME claim
XPIDFILE="$BASE/xvfb.pid"
NPIDFILE="$BASE/nspawn.pid"
XSOCK="/tmp/.X11-unix/X${DISP#:}"

[ -x "$BIN" ] || {
  echo "vax43bsd[$TILE]: no SIMH vax780 at $BIN" >&2
  exit 1
}
[ -f "$SEED" ] || {
  echo "vax43bsd[$TILE]: no seed RA81 at $SEED" >&2
  exit 1
}
[ -f "$ASSETS/media/boot42" ] || {
  echo "vax43bsd[$TILE]: no standalone boot at $ASSETS/media/boot42" >&2
  exit 1
}
[ -x "$ROOTFS/usr/bin/xterm" ] || {
  echo "vax43bsd[$TILE]: no container rootfs at $ROOTFS" >&2
  exit 1
}
for f in "$INNER" "$SHARED"; do
  [ -f "$f" ] || {
    echo "vax43bsd[$TILE]: missing $f" >&2
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
  echo "vax43bsd[$TILE]: previous simulator still alive after SIGKILL:" \
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
  echo "vax43bsd[$TILE]: $XSOCK exists and is not our symlink — display $DISP is someone else's" >&2
  exit 1
fi
mkdir -p /tmp/.X11-unix
ln -sfn "$SOCKDIR/X${DISP#:}" "$XSOCK"

# --- pristine per-launch state. work/ is the only writable bind and holds the
# ONLY disk the simulator ever attaches; the seed in media/ is mode 0444 and
# bound read-only. THE SEED MUST HAVE BEEN SNAPSHOTTED FROM A GUEST THAT RAN
# `sync; sync; /etc/halt` — a dirty 4.3BSD filesystem is salvaged at boot and
# the guest then REBOOTS ITSELF, which from outside is indistinguishable from a
# station in a boot loop (docs/lab/record-wave/shared-terminal-runtime.sh).
rm -rf "$BASE/work"
mkdir -p "$BASE/work"
cp --sparse=always "$SEED" "$BASE/work/ra81.dsk"
chown -R "$UIDBASE:$UIDBASE" "$BASE/work"
chmod 0644 "$BASE/work/ra81.dsk"
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$INNER" "$BASE/work/nspawn-inner.sh"
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$SHARED" "$BASE/work/shared-terminal-runtime.sh"

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
  --setenv=VAX43BSD_ASSETS="$ASSETS" \
  --setenv=VAX43BSD_GEOM="$GEOM" \
  --setenv=VAX43BSD_PORT="$PORT" \
  --setenv=VAX43BSD_COLS="${VAX43BSD_COLS:-80}" \
  --setenv=VAX43BSD_ROWS="${VAX43BSD_ROWS:-24}" \
  --setenv=VAX43BSD_FONTSIZE="${VAX43BSD_FONTSIZE:-14}" \
  --setenv=VAX43BSD_XOFF="${VAX43BSD_XOFF:-+32+96}" \
  --setenv=HOME=/work --setenv=TERM=vt100 \
  --kill-signal=SIGTERM --console=pipe \
  /work/nspawn-inner.sh \
  >"$BASE/vax43bsd.log" 2>&1 </dev/null &
echo $! >"$NPIDFILE"

# 4.3BSD reaches the console `login:` in ~53 s from a clean seed (MEASURED
# 2026-09-20, `set cpu idle=32v`; the bulk is the boot-time fsck of ra0a/h/g).
# Wait on the real things: the simulator pid, the X socket, and the visitor
# window actually mapped — never on a guessed sleep.
SPID=""
for _ in $(seq 1 "${VAX43BSD_LAUNCH_TIMEOUT_S:-360}"); do
  kill -0 "$(cat "$NPIDFILE")" 2>/dev/null || {
    echo "vax43bsd[$TILE]: container died at launch — tail of vax43bsd.log:" >&2
    tail -40 "$BASE/vax43bsd.log" >&2
    exit 1
  }
  SPID="$(station_vm_pids | head -1)"
  if [ -n "$SPID" ] && [ -S "$SOCKDIR/X${DISP#:}" ] &&
    xwininfo -root -tree -display "$DISP" 2>/dev/null | grep -q "4.3BSD console"; then
    break
  fi
  SPID=""
  sleep 1
done
[ -n "$SPID" ] || {
  echo "vax43bsd[$TILE]: no 4.3BSD terminal window — tail of vax43bsd.log:" >&2
  tail -40 "$BASE/vax43bsd.log" >&2
  tail -40 "$BASE/work/emulator.log" 2>/dev/null >&2 || true
  exit 1
}

# --- focus, and wake the getty. MEASURED 2026-09-20, and both halves are
# required:
#
#  * No window manager runs in the container, so X input focus is PointerRoot
#    and keystrokes reach the xterm only while the pointer happens to be over
#    it. The daemon drives this station with XTEST keys and never moves a
#    pointer (there is none in the exhibit), so without an explicit
#    XSetInputFocus a visitor's typing would land on the root window and
#    vanish. `xdotool windowfocus` pins it once, for good.
#
#  * 4.3BSD's getty prints its `login:` banner when it opens the line, which on
#    a SIMH DZ11 happens at boot — long before any visitor connects — and the
#    banner goes into the void. A telnet connection does NOT re-trigger it:
#    measured, a passive connect sat silent for 25 s on a line whose getty was
#    alive and well. One CR makes getty re-print, so the rest scene is the
#    login prompt instead of a black screen. This is a bring-up action by the
#    launcher on the station's own display, not a hidden shortcut offered to
#    the visitor.
#
# The CR is re-sent until the LOGIN BANNER is actually on the framebuffer —
# the banner is the proof, not the keystroke. "Did the screen change" is too
# weak here: the telnet chrome and SIMH's own "Connected to ... line 0"
# greeting arrive asynchronously in the same window, and an early CR that
# reaches the line before getty is listening is simply lost. So the gate is a
# lit-pixel count. MEASURED 2026-09-20 on this station's own Xvfb: telnet
# chrome alone = 2958 lit pixels, chrome + greeting + two banners = 9148, i.e.
# one banner is worth about 2000 and a cursor blink about 90.
export DISPLAY="$DISP"
nlit() {
  xwd -display "$DISP" -root -silent 2>/dev/null |
    convert xwd:- -colorspace Gray -threshold 25% -format '%[fx:int(mean*w*h)]' info: 2>/dev/null || echo 0
}
WIN="$(xdotool search --name '4.3BSD console' 2>/dev/null | head -1 || true)"
if [ -n "$WIN" ]; then
  xdotool windowfocus "$WIN" 2>/dev/null || true
  # Let the telnet chrome and SIMH's own "Connected to ... line 0" greeting
  # finish arriving before the baseline is taken, or the baseline is a blank
  # window and the chrome alone clears the threshold.
  base=-1
  prev=-1
  same=0
  for _ in $(seq 1 60); do
    sleep 0.5
    base="$(nlit)"
    if [ "$base" -gt 0 ] && [ "$base" = "$prev" ]; then
      same=$((same + 1))
      [ "$same" -ge 4 ] && break
    else
      same=0
    fi
    prev="$base"
  done
  want=$((base + ${VAX43BSD_BANNER_LIT_PX:-1200}))
  got="$base"
  for _ in $(seq 1 "${VAX43BSD_GETTY_WAKE_TRIES:-20}"); do
    xdotool key --clearmodifiers Return 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8; do
      sleep 0.5
      got="$(nlit)"
      [ "$got" -ge "$want" ] && break 2
    done
  done
  if [ "$got" -ge "$want" ]; then
    echo "vax43bsd[$TILE]: login banner on the framebuffer ($base -> $got lit px)"
  else
    echo "vax43bsd[$TILE]: WARNING — no login banner (lit px $base -> $got, wanted $want); the rest scene may open black" >&2
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
echo "vax43bsd[$TILE]: vax780=$SPID xvfb=${XV:-?} nspawn=$(cat "$NPIDFILE") display=$DISP geom=$GEOM dz=$PORT uidbase=$UIDBASE (contained relaunch from the pristine seed RA81)"

# Standby: freeze the simulator once the login prompt has settled; the daemon
# owns the steady state via SH_IDLE_PAUSE_PIDFILE and SIGCONTs on the first
# session. A frozen VAX costs no core between visitors.
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${VAX43BSD_STANDBY_DELAY_S:-30}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = "$BIN" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "vax43bsd[$TILE]: standby — frozen at the 4.3BSD login (pid $p; first session wakes it)"
  ) &
fi
