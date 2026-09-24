#!/bin/bash
# =============================================================================
# stations/nokia9300/x11-runtime.sh — launcher for the Nokia 9300 Communicator
# station (Series 80 v2 on Symbian OS 7.0s, the real RAE-6 firmware), CONTAINED.
# Started by ensure-station-x11.sh inside the streamhost@nokia9300 BindsTo
# scope; the daemon captures the X root (SH_CAPTURE=x11) and types over XTEST
# (SH_INPUT_BACKEND=x11test, keys only — a Nokia 9300 has no pointer).
#
# THE SHAPE (lisa/perq/its): EKA2L1 — the Symbian HLE emulator, our fork
# github.com/Wnt/EKA2L1 branch s80-epoc7-tables (GPL-3), which carries the
# Series 80 v2 window-server opcode table that makes the 9300's own apps paint —
# is a stock Qt 6 + OpenGL host application, so it runs under the operator's
# host-application rule (2026-09-09, the medley incident) inside a
# systemd-nspawn container:
#   * root filesystem: $ROOTFS, a trixie tree with the Qt 6 / Mesa runtime,
#     Xvfb, xdotool and x11-utils, uid-shifted ONCE to $UIDBASE by the builder,
#     mounted --volatile=overlay (writes land in RAM, the tree stays pristine);
#   * the EKA2L1 build dir bound READ-ONLY at its own host path, so the host's
#     /proc/<pid>/exe of the sandboxed emulator names the real binary;
#   * the golden data dir bound READ-ONLY at /golden (the RAE-6 ROM, the Z:
#     tree, the C: drive and EKA2L1's config — never in git, see the builder);
#   * writable: only $BASE/work (this launch's copy of the data dir, logs) and
#     $SOCKDIR (the Xvfb socket dir, bound over the container's /tmp/.X11-unix;
#     the host symlinks /tmp/.X11-unix/X<n> to it for the daemon's DISPLAY);
#   * --private-network (lo only) until the retronet plane is proven — agents
#     N1/N2 own it, and its rn-tapnet.sh stays uncommitted until then (rule 15);
#   * capabilities dropped, @mount filtered, no new privileges.
# nokia9300-inner.sh (PID 2 inside) starts Xvfb and SUPERVISES EKA2L1 — a
# fresh golden copy per launch, relaunch when it exits — and places the Qt
# window so the root IS the 640x200 screen at 2x; its header has the geometry.
#
# RESET = RELAUNCH. EKA2L1 has no save state for this path, and the nspawn
# CRIU route is blocked by the sandbox's seccomp filter (memory note
# nspawn-criu-reset-blocked-by-seccomp), so reset = kill the container, copy
# the golden fresh, cold-start. Desk paints ~3.5 s after exec on an idle host.
#
# Per-station knobs (station.env, the systemd EnvironmentFile):
#   SH_STATION           station id == station dir name
#   SH_X11_DISPLAY       the pinned Xvfb display (:119)
#   NOKIA_ASSETS         /data/vms/streamhost/assets/nokia9300 (eka2l1/, rootfs/)
#   NOKIA_EMU_DIR        EKA2L1 build dir (default $NOKIA_ASSETS/eka2l1)
#   NOKIA_ROOTFS         container tree (default $NOKIA_ASSETS/rootfs)
#   NOKIA_GOLDEN         golden XDG data root (default $BASE/golden)
#   NOKIA_GEOM           Xvfb root == the screen at 2x (default 1280x400)
#   NOKIA_DEVICE         EKA2L1 firmware code (RAE-6 = the Nokia 9300)
#   NOKIA_APP            app UID for --run (0x101f8e4f = Desk, the S80 shell)
#   NOKIA_EMU_ARGS       extra eka2l1_qt flags (B2's kiosk flags, when they exist)
#   NOKIA_LOG_FILTER     EKA2L1 log-filter for the live copy ("" keeps the golden's)
#   NOKIA_UID_BASE       host uid the container's uid 0 maps to (2621440)
#   NOKIA_X11_SOCKDIR    host dir bound over /tmp/.X11-unix
#   NOKIA_MACHINE        nspawn machine name (default kh-$SH_STATION; rigs override)
#   NOKIA_BASE           override for $BASE on a rig (unset in production)
#   SH_IDLE_PAUSE_*      the daemon's freezer reads mame.pid (kept current here)
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${NOKIA_BASE:-/data/vms/streamhost/stations/$TILE}"
ASSETS="${NOKIA_ASSETS:-/data/vms/streamhost/assets/nokia9300}"
EMU_DIR="${NOKIA_EMU_DIR:-$ASSETS/eka2l1}"
ROOTFS="${NOKIA_ROOTFS:-$ASSETS/rootfs}"
GOLDEN="${NOKIA_GOLDEN:-$BASE/golden}"
GEOM="${NOKIA_GEOM:-1280x400}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
UIDBASE="${NOKIA_UID_BASE:-2621440}"
SOCKDIR="${NOKIA_X11_SOCKDIR:-/run/streamhost/x11/$TILE}"
MACHINE="${NOKIA_MACHINE:-kh-$TILE}"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name every native launcher uses
XPIDFILE="$BASE/xvfb.pid"
NSPAWN_PIDFILE="$BASE/nspawn.pid"
INNER="$(dirname "$(readlink -f "$0")")/nokia9300-inner.sh"
WORK="$BASE/work"
XSOCK="/tmp/.X11-unix/X${DISP#:}"
BIN="$EMU_DIR/eka2l1_qt"
say() { echo "nokia9300[$TILE]: $*"; }
die() {
  echo "nokia9300[$TILE]: $*" >&2
  exit 1
}

[ -x "$BIN" ] || die "no EKA2L1 at $BIN — run scripts/build-guests/tiles/nokia9300.sh"
[ -d "$EMU_DIR/resources" ] && [ -d "$EMU_DIR/patch" ] ||
  die "$EMU_DIR lacks resources/ or patch/ (EKA2L1 copies both into its data dir at start)"
for t in Xvfb xdotool xwininfo; do
  [ -x "$ROOTFS/usr/bin/$t" ] || die "no $t in the container rootfs $ROOTFS — run tiles/nokia9300.sh --rootfs"
done
[ "$(stat -c %u "$ROOTFS")" = "$UIDBASE" ] ||
  die "rootfs $ROOTFS is owned by uid $(stat -c %u "$ROOTFS"), not the container base $UIDBASE"
[ -f "$GOLDEN/EKA2L1/data/devices.yml" ] || die "no golden data dir at $GOLDEN (EKA2L1/data/devices.yml)"
[ -f "$INNER" ] || die "missing $INNER"

# --- reap by /proc/<pid>/exe, scoped by DESCENT from this launch's nspawn --------
# A bare exe match is not a scope: a rig and the live station run the same
# binary path, and perq measured each reaping the other's emulator
# (2026-09-13). The ppid table is read ONCE and walked in awk (perq: a fork per
# hop never returned at load 60).
station_descendants() {
  ps -eo pid=,ppid= | awk -v root="$1" '
    { ppid[$1] = $2 }
    END {
      for (p in ppid) {
        q = p
        for (h = 0; h < 24; h++) {
          q = ppid[q]
          if (q == root) { print p; break }
          if (q <= 1) break
        }
      }
    }'
}
station_nspawn_pid() {
  local p
  p="$(cat "$NSPAWN_PIDFILE" 2>/dev/null || true)"
  case "$p" in '' | *[!0-9]*) return 1 ;; esac
  [ "$(readlink "/proc/$p/exe" 2>/dev/null)" = "$(readlink -f "$(command -v systemd-nspawn)")" ] || return 1
  grep -qa -- "--machine=$MACHINE" "/proc/$p/cmdline" 2>/dev/null || return 1
  echo "$p"
}
station_emu_pids() { # station_emu_pids [nspawn-pid] (default: the pidfile's)
  local n="${1:-}" p exe
  [ -n "$n" ] || n="$(station_nspawn_pid)" || return 0
  for p in $(station_descendants "$n"); do
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
    case "${exe% (deleted)}" in */eka2l1_qt) printf '%s\n' "$p" ;; esac
  done
}
# Kill the CONTAINER, not the supervisor. MEASURED 2026-09-24 on the rig: a
# SIGTERM to systemd-nspawn never reached the inner script's TERM trap (its
# SigCgt had TERM; the trap did not run in 10 s), the inner loop relaunched the
# emulator the reaper had just killed, and the fallback SIGKILL of nspawn then
# orphaned the whole container AND left /run/systemd/nspawn/unix-export/<machine>
# behind, so the next launch died with "Mount point … exists already". nspawn's
# direct child is the container's init (the "(sd-stubinit)" of --as-pid2):
# SIGKILL it and the kernel kills every process in the PID namespace, after
# which nspawn exits on its own and cleans up its mounts. Nothing inside needs a
# graceful stop — EKA2L1 ignores SIGTERM and work/ is discarded anyway.
reap_previous() {
  local n p
  n="$(station_nspawn_pid || true)"
  [ -n "$n" ] || return 0
  for p in $(ps -o pid= --ppid "$n" 2>/dev/null); do
    kill -KILL "$p" 2>/dev/null || true
  done
  for _ in $(seq 1 40); do
    station_nspawn_pid >/dev/null || return 0
    sleep 0.25
  done
  # Last resort: the supervisor itself (may leave the unix-export mount point).
  kill -KILL "$n" 2>/dev/null || true
  sleep 0.5
  ! station_nspawn_pid >/dev/null
}
reap_previous || die "the previous sandbox is still alive after SIGKILL — refusing to start a second one"
[ ! -e "/run/systemd/nspawn/unix-export/$MACHINE" ] ||
  die "/run/systemd/nspawn/unix-export/$MACHINE exists — an orphaned container named $MACHINE (a SIGKILLed nspawn leaves its init running); kill its (sd-stubinit) first"
rm -f "$PIDFILE" "$XPIDFILE" "$NSPAWN_PIDFILE" "$WORK/placed"

# --- host side of the X socket --------------------------------------------------
mkdir -p "$SOCKDIR"
chown "$UIDBASE:$UIDBASE" "$SOCKDIR"
chmod 1777 "$SOCKDIR"
rm -f "$SOCKDIR/X${DISP#:}"
if [ -e "$XSOCK" ] && [ ! -L "$XSOCK" ]; then
  die "$XSOCK exists and is not our symlink — display $DISP is someone else's"
fi
mkdir -p /tmp/.X11-unix
ln -sfn "$SOCKDIR/X${DISP#:}" "$XSOCK"

# --- pristine per-launch state: work/ is the only writable bind ----------------
rm -rf "$WORK"
mkdir -p "$WORK"
chown "$UIDBASE:$UIDBASE" "$WORK"
# The inner script travels as an emit aux file (root, 0600 in the station dir);
# the container's mapped root could not read it there (perq).
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$INNER" "$WORK/inner.sh"

nohup systemd-nspawn --quiet --register=no --keep-unit --as-pid2 \
  --machine="$MACHINE" --uuid="$(printf '%032x' "$UIDBASE")" \
  --directory="$ROOTFS" --volatile=overlay \
  --private-users="$UIDBASE:65536" --private-users-ownership=off \
  --private-network \
  --drop-capability=CAP_SYS_ADMIN,CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE \
  --no-new-privileges=yes \
  --system-call-filter='~@mount' \
  --bind-ro="$EMU_DIR" --bind-ro="$GOLDEN:/golden" \
  --bind="$WORK:/work" --bind="$SOCKDIR:/tmp/.X11-unix" \
  --setenv=NOKIA_DISPLAY="$DISP" --setenv=NOKIA_GEOM="$GEOM" \
  --setenv=NOKIA_EMU_DIR="$EMU_DIR" --setenv=NOKIA_DEVICE="${NOKIA_DEVICE:-RAE-6}" \
  --setenv=NOKIA_APP="${NOKIA_APP:-0x101f8e4f}" --setenv=NOKIA_EMU_ARGS="${NOKIA_EMU_ARGS:-}" \
  --setenv=NOKIA_LOG_FILTER="${NOKIA_LOG_FILTER-}" \
  --setenv=NOKIA_WINDOW_TITLE="${NOKIA_WINDOW_TITLE:-Symbian OS emulator}" \
  --setenv=LANG=C.UTF-8 \
  --kill-signal=SIGTERM --console=pipe \
  /work/inner.sh >"$BASE/nokia9300.log" 2>&1 </dev/null &
echo $! >"$NSPAWN_PIDFILE"

# --- ready = the emulator exists AND the inner script placed its window ------------
EPID=""
for _ in $(seq 1 "${NOKIA_LAUNCH_TIMEOUT_S:-90}"); do
  kill -0 "$(cat "$NSPAWN_PIDFILE")" 2>/dev/null || {
    echo "nokia9300[$TILE]: the sandbox died at launch — tail of nokia9300.log:" >&2
    tail -30 "$BASE/nokia9300.log" >&2
    exit 1
  }
  EPID="$(station_emu_pids | head -1)"
  [ -n "$EPID" ] && [ -S "$SOCKDIR/X${DISP#:}" ] && [ -e "$WORK/placed" ] && break
  sleep 1
done
[ -n "$EPID" ] || {
  echo "nokia9300[$TILE]: EKA2L1 did not appear — tail of nokia9300.log:" >&2
  tail -30 "$BASE/nokia9300.log" >&2
  exit 1
}
[ -e "$WORK/placed" ] || say "WARNING — no placement marker yet; the first frames may show window chrome"
echo "$EPID" >"$PIDFILE"
for d in /proc/[0-9]*; do
  p="${d#/proc/}"
  [ "$(basename "$(readlink "$d/exe" 2>/dev/null)")" = Xvfb ] || continue
  [ "$(readlink "$d/ns/pid" 2>/dev/null)" = "$(readlink "/proc/$EPID/ns/pid" 2>/dev/null)" ] || continue
  echo "$p" >"$XPIDFILE"
done
say "pid=$EPID xvfb=$(cat "$XPIDFILE" 2>/dev/null || echo ?) nspawn=$(cat "$NSPAWN_PIDFILE")" \
  "display=$DISP root=$GEOM device=${NOKIA_DEVICE:-RAE-6} app=${NOKIA_APP:-0x101f8e4f} uidbase=$UIDBASE" \
  "(contained cold start from a fresh golden copy)"

# --- keep mame.pid on the CURRENT emulator ----------------------------------------
# The inner loop relaunches EKA2L1 when it exits, under a new pid; the daemon's
# idle freezer re-reads this pidfile on every stop/cont (streamhost idle.rs),
# so following the relaunch here is all it needs.
# The follower is pinned to THIS launch's supervisor: once a relaunch rewrites
# nspawn.pid, or this nspawn exits, it stops rather than adopt the next one.
NPID="$(cat "$NSPAWN_PIDFILE")"
(
  while kill -0 "$NPID" 2>/dev/null && [ "$(cat "$NSPAWN_PIDFILE" 2>/dev/null)" = "$NPID" ]; do
    sleep "${NOKIA_PIDWATCH_S:-3}"
    p="$(station_emu_pids "$NPID" | head -1)"
    [ -n "$p" ] || continue
    [ "$p" = "$(cat "$PIDFILE" 2>/dev/null || true)" ] && continue
    echo "$p" >"$PIDFILE"
    say "EKA2L1 relaunched inside the sandbox — mame.pid now $p"
  done
) &
