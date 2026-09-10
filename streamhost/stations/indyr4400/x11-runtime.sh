#!/bin/bash
# =============================================================================
# stations/indyr4400/x11-runtime.sh — the SGI Indy R4400 / IRIX 6.5 station,
# HOST-NATIVE and CONTAINED. Started by ensure-station-x11.sh inside the
# streamhost@indyr4400 BindsTo scope.
#
# THE NAME IS A CONTRACT, NOT A DESCRIPTION. ensure-station-x11.sh execs
# `$BASE/x11-runtime.sh` for every SH_STATION_RUNTIME=x11 station; getting the
# name wrong cold-boots the exhibit (~7 min here) on every daemon restart.
#
# WHAT CHANGED. Until 2026-09 this station was a BRIDGE: a captured Debian 12
# kiosk under QEMU/KVM, running Iris (a userspace Rust SGI Indy emulator) as a
# winit window on a bare X root, captured over QEMU's D-Bus display. One
# pointer move took 361 ms to reach the framebuffer against the MAME `irix`
# sibling's 68 ms, and the wave that measured it concluded the lag was the
# BRIDGE, not the emulator core: QEMU PS/2 -> guest X -> winit -> Iris ->
# llvmpipe -> dbus. Rule 13 says the end state is host-native, so every one of
# those layers is deleted here.
#
# TWO CAPTURE MODES, ONE LAUNCHER, keyed on SH_CAPTURE:
#
#   shm  WHAT SHIPS. No QEMU, no kiosk, no X server, no DISPLAY, no window.
#        Iris publishes its own three planes and the daemon consumes them with
#        env alone (the `nextstep` bar: zero streamhost code):
#          frames  IRIS_SHM_PATH  -> SH_CAPTURE=shm  (IFB1, the producer's own
#                  dirty rect, hence SH_SHM_DAMAGE=0)
#          input   IRIS_CTL_SOCK  -> SH_INPUT_BACKEND=mamesock (mamectl/1)
#          audio   off (IRIX HAL2 through Iris is unexercised; docs/lab/
#                  IRIS-DEBRIDGE-BRIEF.md §5 Q4)
#        Requires the fork (github.com/Wnt/iris) — stock Iris installs no
#        Renderer on its no-window branch and publishes a black frame.
#
#   x11  THE INTERIM PROOF, and the fallback. A pinned Xvfb inside the same
#        container and Iris as an ordinary window on it, captured with
#        SH_CAPTURE=x11 and driven over XTEST. It exists so the container, the
#        binds, the pidfile contract, the reap path, the streamhost attach and
#        the /os/<id> publication path are proven BEFORE the fork lands, and so
#        that a fork regression has somewhere to fall back to. It keeps the
#        llvmpipe + X round trip and is nowhere near shm's latency.
#
# CONTAINED, and not optionally. Iris is third-party code that opens loopback
# TCP listeners of its own (the monitor console on 127.0.0.1:8888 is hardcoded
# and always started, src/machine.rs), so it runs inside a systemd-nspawn
# container in the shape docs/guests/medley.md §Security and docs/guests/lisa.md
# §Sandbox established after the 2026-09-09 medley incident:
#
#   * own PID / mount / network / IPC / UTS / user namespaces; --private-users
#     means "root" inside is host uid IRIS_UID_BASE and cannot mount a host
#     filesystem, read a host file it was not handed, or signal a host process;
#   * --private-network: only `lo`. The monitor console is therefore reachable
#     only from inside the netns (`nsenter -t <mame.pid> -n`), which is a
#     feature: stream C/D drive the machine over the ci socket instead;
#   * --read-only root: $ASSETS/rootfs is a SKELETON of mount points and
#     symlinks with the host's /usr bound in read-only. Nothing in the root is
#     writable at all -- strictly stronger than medley's --volatile=overlay,
#     and it needs no uid-shifted tree;
#   * READ-ONLY: the Iris binary and the 6.3 GB IRIX disk, each bound AT ITS
#     HOST PATH so /proc/<pid>/exe and SH_IDLE_PAUSE_PROC_MATCH read the same
#     from inside and out (lisa.md §Sandbox);
#   * WRITABLE: $BASE/work only (iris.toml, nvram, the disk COW overlay, logs),
#     plus $BASE/run for the two sockets Iris must bind itself and, in shm
#     mode, the pre-created $BASE/fb.shm mapping;
#   * CAP_SYS_ADMIN and friends dropped, @mount filtered, no-new-privileges.
#
# THE DISK IS NEVER DIRTIED. iris.toml points at /work/disk.raw, a SYMLINK to
# the read-only bind, and `overlay = true` puts every guest write in
# /work/disk.raw.overlay on the station's own disk. The bridge did the same
# thing through the guest's /srv/irix mount; this is that trick with the kiosk
# removed. In shm mode /tmp inside the container is a BIND to $BASE/work/tmp
# rather than nspawn's tmpfs, because Iris redirects a `overlay = true` device's
# COW file to /tmp/iris-ci-<pid>-scsiN.overlay in ci mode (src/machine.rs:472)
# and a 6.3 GB disk's COW in a tmpfs is RAM.
#
# RESET, TWO WAYS. The cheap one is in-process: `reset-tile.sh`'s relaunch
# branch sends `LOADST golden` down the station's ONE mamectl/1 socket and the
# emulator rewinds itself in 0.19-1.6 s without this script running at all. The
# expensive one is a unit restart, whose ExecStartPre lands back here: the
# container is killed, work/ is wiped and the machine is restored from
# IRIS_STATE at startup (4.1-5.9 s) or, with IRIS_STATE empty, cold booted.
# A cold boot is ~7 minutes (PROM -> IRIX autoconfig relink -> login) and it
# says so loudly in the log, because it is a visibly degraded exhibit.
#
# work/ IS WIPED AND state/ IS NOT. The snapshots are the one thing a relaunch
# must not destroy, and `saves/<name>` is resolved against the emulator's CWD
# (/work) — so /work/saves is a symlink to the persistent /state bind. Getting
# this wrong deletes the golden with the reset that was meant to restore it.
#
# PIDFILE CONTRACT (ensure/stop-station-x11.sh, idle.rs):
#   mame.pid    Iris's HOST-visible pid — the daemon SIGSTOP/SIGCONTs it and
#               the reaper resolves it through /proc/<pid>/exe, never a
#               cmdline grep (AGENTS.md rule 5);
#   xvfb.pid    the container's Xvfb (x11 mode only);
#   nspawn.pid  the supervisor, so a leaked container never lingers.
#
# Knobs (station.env, the systemd EnvironmentFile):
#   SH_STATION SH_CAPTURE SH_X11_DISPLAY SH_SHM_PATH SH_MAMECTL_SOCK
#   SH_MAMESOCK_KEYMAP SH_IDLE_PAUSE_PIDFILE SH_IDLE_PAUSE_SECS
#   IRIS_ASSETS IRIS_BIN IRIS_DISK IRIS_GEOM IRIS_MEM_BANKS IRIS_STATE
#   IRIS_CI_SOCK IRIS_PTR_MODE IRIS_UID_BASE IRIS_STANDBY_DELAY_S
#   IRIS_MONITOR_ADDR KH_PROVENANCE IRIS_BASE (rig override)
# The emulator geometry knobs are NOT separate keys: IRIS_SHM_GEOMETRY (the
# published crop) and IRIS_CTL_SCREEN (the pointer clamp + the HELLO banner)
# both come from IRIS_GEOM, so the frame the daemon maps, the surface the
# browser clamps to and the rectangle the registry declares cannot drift apart.
# VC2 decodes 1282x1024 on this machine — two columns of real right-edge
# overscan — and 1280x1024 is what the station publishes.
# See docs/lab/IRIS-DEBRIDGE-LEDGER.md for the values and who owns each one.
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${IRIS_BASE:-/data/vms/streamhost/stations/$TILE}"
ASSETS="${IRIS_ASSETS:-/data/vms/streamhost/assets/$TILE}"
BIN="${IRIS_BIN:-$ASSETS/iris}"
ROOTFS="${IRIS_ROOTFS:-$ASSETS/rootfs}"
DISK="${IRIS_DISK:-/data/gallery-guests/IrisIndy/irix65-r4400-disk.raw}"
CAPTURE="${SH_CAPTURE:-shm}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
GEOM="${IRIS_GEOM:-1280x1024}"
BANKS="${IRIS_MEM_BANKS:-[128, 128, 0, 0]}"
UIDBASE="${IRIS_UID_BASE:-2031616}"
STATE="${IRIS_STATE:-}"
PTR_MODE="${IRIS_PTR_MODE:-rel}"
MACHINE="kh-$TILE"

WORK="$BASE/work"
RUN="$BASE/run"
X11DIR="$BASE/x11"
# THE CHECKPOINT DOES NOT LIVE IN work/. `Machine::save_snapshot` resolves
# `saves/<name>` against the PROCESS CWD, which is /work — and work/ is wiped on
# every launch, which is the reset. A golden written there would be destroyed by
# the next restart, i.e. by the very thing that is supposed to restore it. So the
# snapshots (and the shared CAS chunk store under `saves/.cas`) live in their own
# persistent directory and /work/saves is a symlink to it, exactly as
# /work/disk.raw is a symlink to the read-only asset.
STATE_DIR="$BASE/state"
SHM="${SH_SHM_PATH:-$RUN/fb.shm}"
CTL="${SH_MAMECTL_SOCK:-$RUN/ctl.sock}"
# The monitor console binds a HARDCODED 127.0.0.1:8888 upstream, which is a
# process-wide singleton: a rig beside the station silently loses it. Inside
# --private-network this is the container's own loopback, so the port is
# private, but naming it keeps a rig launched with the same script honest.
MONITOR="${IRIS_MONITOR_ADDR:-127.0.0.1:18136}"
# strict = refuse a checkpoint captured by a different binary. Golden + binary
# + device set are ONE combination (rule 6); `warn` is for a DELIBERATE binary
# bump whose state is known good, and it says so in the log.
PROVENANCE="${KH_PROVENANCE:-strict}"
# No default: an EMPTY IRIS_CI_SOCK means "no --ci", and a `:-` default would
# quietly turn that back on (nspawn-inner.sh keys the mode off this value).
CISOCK="${IRIS_CI_SOCK-}"
KEYMAP="${SH_MAMESOCK_KEYMAP:-$BASE/indy.keymap}"
PIDFILE="$BASE/mame.pid"
XPIDFILE="$BASE/xvfb.pid"
NPIDFILE="$BASE/nspawn.pid"
LOG="$BASE/iris.log"
INNER="$BASE/nspawn-inner.sh"
[ -f "$INNER" ] || INNER="$(dirname "$(readlink -f "$0")")/nspawn-inner.sh"
RESET="$BASE/kh-reset.sh"
[ -f "$RESET" ] || RESET="$(dirname "$(readlink -f "$0")")/kh-reset.sh"

say() { printf 'iris[%s]: %s\n' "$TILE" "$*"; }
die() {
  printf 'iris[%s]: %s\n' "$TILE" "$*" >&2
  exit 1
}

# --- preflight: fail closed, never fall back ---------------------------------
[ -x "$BIN" ] || die "no iris binary at $BIN — run scripts/build-guests/tiles/indyr4400.sh"
[ -f "$DISK" ] || die "no IRIX disk asset at $DISK — run $BASE/fetch-assets.sh"
[ -d "$ROOTFS/usr" ] && [ -f "$ROOTFS/etc/os-release" ] ||
  die "no container rootfs skeleton at $ROOTFS — run scripts/build-guests/tiles/indyr4400.sh --rootfs"
[ -f "$INNER" ] || die "missing $INNER (it travels as an emit --aux-file)"
[ -f "$RESET" ] || die "missing $RESET (it travels as an emit --aux-file)"
case "$CAPTURE" in
  shm)
    # The mamectl/1 keymap is stream C's file and the daemon needs it the moment
    # SH_INPUT_BACKEND=mamesock is live. Missing it is a dead keyboard with no
    # error anywhere, so refuse to start rather than serve a half-exhibit.
    [ -s "$KEYMAP" ] || die "SH_CAPTURE=shm needs the mamectl keymap at $KEYMAP"
    ;;
  x11) ;;
  *) die "unknown SH_CAPTURE=$CAPTURE (shm | x11)" ;;
esac

# --- reap: Iris by /proc/<pid>/exe scoped to THIS station's asset dir, then the
# supervisor. SIGCONT before TERM — a SIGSTOPped standby never runs to handle
# it — and refuse to start over a survivor: a `systemctl restart` that leaves
# the old emulator alive put two of them into one mapping on three live
# stations during the MAME wave (DEBRIDGE-HANDOVER.md §Lessons 7).
station_emu_pids() {
  local d p exe
  for d in /proc/[0-9]*; do
    [ -d "$d" ] || continue
    p="${d#/proc/}"
    [ "$p" = "$$" ] && continue
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
    exe="${exe% (deleted)}" # a REPLACED binary still reads back, with a suffix
    case "$exe" in
      "$ASSETS"/*) printf '%s\n' "$p" ;;
    esac
  done
}
station_nspawn_pid() {
  local p
  p="$(cat "$NPIDFILE" 2>/dev/null || true)"
  case "$p" in '' | *[!0-9]*) return 1 ;; esac
  [ "$(readlink "/proc/$p/exe" 2>/dev/null)" = "$(readlink -f "$(command -v systemd-nspawn)")" ] || return 1
  grep -qz -- "--machine=$MACHINE" "/proc/$p/cmdline" 2>/dev/null || return 1
  printf '%s\n' "$p"
}
reap_previous() {
  local p
  if p="$(station_nspawn_pid)"; then kill -TERM "$p" 2>/dev/null || true; fi
  for p in $(station_emu_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  for _ in $(seq 1 40); do
    [ -z "$(station_emu_pids)" ] && ! station_nspawn_pid >/dev/null && return 0
    sleep 0.25
  done
  for p in $(station_emu_pids) $(station_nspawn_pid || true); do
    kill -CONT "$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null || true
  done
  sleep 0.5
  [ -z "$(station_emu_pids)" ]
}
reap_previous ||
  die "previous iris still alive after SIGKILL: $(station_emu_pids | tr '\n' ' ')— refusing to start a second one into one mapping"
rm -f "$PIDFILE" "$XPIDFILE" "$NPIDFILE"

# --- restore or cold boot, decided by the failure ledger --------------------
# `kh_reset_preflight` (stations/indyr4400/kh-reset.sh) sets KH_STATE to the
# checkpoint name, or to empty when there is no checkpoint or when two
# consecutive launches restored one and never acked a verb. Iris has no
# `--restore` flag, so a bad checkpoint would otherwise wedge the station in a
# restore loop that looks exactly like a boot loop. IRIS_STATE from station.env
# is the operator's override: setting it empty forces a cold boot.
KH_STATION_DIR="$BASE" KH_CHECKPOINT="${STATE:-golden}" KH_SAVES_DIR="$STATE_DIR"
export KH_STATION_DIR KH_CHECKPOINT KH_SAVES_DIR
# shellcheck source=/dev/null
. "$RESET"
if [ -n "$STATE" ]; then
  kh_reset_preflight
  STATE="$KH_STATE"
fi

# --- pristine per-launch state, owned by the container's root ----------------
# work/ is wiped every launch: that IS the reset. run/ is recreated so a stale
# socket can never be mistaken for a live one.
rm -rf "$WORK" "$RUN" "$X11DIR"
mkdir -p "$WORK/tmp" "$RUN" "$X11DIR" "$STATE_DIR"
ln -sfn "$DISK" "$WORK/disk.raw"
# /work/saves -> the persistent state dir. Dangling from the host's point of
# view (the target is a container path) and correct from inside, the same shape
# the disk symlink above uses. Iris writes saves/<name>/ and saves/.cas here.
ln -sfn /state "$WORK/saves"
cat >"$WORK/iris.toml" <<TOML
# iris.toml — written fresh by x11-runtime.sh on every launch; edit the
# launcher, not this file. disk.raw is a SYMLINK to the read-only asset and
# overlay = true keeps every guest write in /work/disk.raw.overlay.
headless = false
no_audio = true
scale    = 1
banks    = $BANKS
nvram    = "/work/nvram.bin"

[scsi.1]
path    = "/work/disk.raw"
cdrom   = false
overlay = true
TOML
# The inner script travels as an emit --aux-file: root-owned 0600 in the station
# dir, which the container's MAPPED root can neither read nor execute. Install a
# copy into work/ with the container's ownership (medley's trap, verbatim).
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$INNER" "$WORK/nspawn-inner.sh"
chown -R "$UIDBASE:$UIDBASE" "$WORK" "$RUN" "$X11DIR"
# NOT -R on the state dir: it holds the golden and a 100+ MB chunk store, and
# re-chowning it on every launch would cost a full tree walk for nothing. Only
# the directory itself has to be enterable and writable by the container's root.
chown "$UIDBASE:$UIDBASE" "$STATE_DIR"
chmod 1777 "$X11DIR"

BINDS=(--bind="$WORK:/work" --bind="$RUN" --bind="$STATE_DIR:/state")
if [ "$CAPTURE" = shm ]; then
  # THE MAPPING LIVES IN run/, NOT IN THE STATION DIR, and that is not a matter
  # of taste. The fork's publisher creates a mapping by writing a temp file
  # BESIDE the target and renaming over it (shmpub.rs Mapping::create), so that
  # a consumer holding the old inode keeps a valid mapping across a geometry
  # change. A rename needs a writable DIRECTORY -- binding the file alone into
  # a --read-only root gives the publisher a writable file inside a read-only
  # parent and it dies with `IRIS_SHM_PATH=...: Read-only file system (os error
  # 30)` after REX3 is already up. run/ is bound read-write at its host path and
  # owned by the container's root, so the mapping simply joins the two sockets
  # there. The station dir itself must NOT be handed over: it holds the cert
  # hash and signaling.json.
  BINDS+=(--bind="$WORK/tmp:/tmp")
else
  BINDS+=(--bind="$X11DIR:/tmp/.X11-unix")
fi

# --- the container -----------------------------------------------------------
# --as-pid2: nspawn's stub init is PID 1 and reaps; nspawn-inner.sh is PID 2 and
# execs Iris, so Iris's exit ends the container. --keep-unit: stays in the
# caller's BindsTo scope, so `systemctl stop streamhost@<tile>` sweeps it.
nohup systemd-nspawn \
  --quiet --register=no --keep-unit --as-pid2 \
  --machine="$MACHINE" --uuid="$(printf '%032x' "$UIDBASE")" \
  --directory="$ROOTFS" --read-only \
  --private-users="$UIDBASE:65536" --private-users-ownership=off \
  --private-network \
  --drop-capability=CAP_SYS_ADMIN,CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE \
  --no-new-privileges=yes \
  --system-call-filter='~@mount' \
  --bind-ro=/usr --bind-ro=/etc/ld.so.cache --bind-ro=/etc/alternatives --bind-ro=/etc/fonts \
  --bind-ro="$BIN" --bind-ro="$DISK" \
  "${BINDS[@]}" \
  --setenv=SH_CAPTURE="$CAPTURE" --setenv=SH_X11_DISPLAY="$DISP" \
  --setenv=IRIS_BIN="$BIN" --setenv=IRIS_GEOM="$GEOM" \
  --setenv=IRIS_SHM_PATH="$SHM" --setenv=IRIS_SHM_GEOMETRY="$GEOM" \
  --setenv=IRIS_CTL_SOCK="$CTL" --setenv=IRIS_CTL_SCREEN="$GEOM" \
  --setenv=IRIS_CI_SOCK="$CISOCK" --setenv=IRIS_STATE="$STATE" \
  --setenv=IRIS_CI_OVERLAY_DIR=/work --setenv=IRIS_MONITOR_ADDR="$MONITOR" \
  --setenv=KH_PROVENANCE="$PROVENANCE" \
  --setenv=IRIS_PTR_MODE="$PTR_MODE" --setenv=IRIS_WORK=/work \
  --setenv=HOME=/work --setenv=LIBGL_ALWAYS_SOFTWARE=1 --setenv=GALLIUM_DRIVER=llvmpipe \
  --kill-signal=SIGTERM --console=pipe \
  /bin/bash /work/nspawn-inner.sh \
  >"$LOG" 2>&1 </dev/null &
echo $! >"$NPIDFILE"

alive_or_die() {
  kill -0 "$(cat "$NPIDFILE")" 2>/dev/null || {
    say "the container died at launch — tail of $LOG:" >&2
    tail -30 "$LOG" >&2
    exit 1
  }
}

# --- the frame source. NOTHING WAITS ON A GUESSED SLEEP (AGENTS.md rule 14):
# every wait below polls real state and fails loudly with the log.
if [ "$CAPTURE" = x11 ]; then
  XSOCK="$X11DIR/X${DISP#:}"
  for _ in $(seq 1 120); do
    [ -S "$XSOCK" ] && break
    alive_or_die
    sleep 0.25
  done
  [ -S "$XSOCK" ] || die "no X socket at $XSOCK after 30 s"
  mkdir -p /tmp/.X11-unix
  HOSTSOCK="/tmp/.X11-unix/X${DISP#:}"
  if [ -e "$HOSTSOCK" ] && [ ! -L "$HOSTSOCK" ]; then
    die "$HOSTSOCK exists and is not our symlink — display $DISP is someone else's"
  fi
  ln -sfn "$XSOCK" "$HOSTSOCK"
fi

IPID=""
for _ in $(seq 1 240); do
  IPID="$(station_emu_pids | head -1)"
  [ -n "$IPID" ] && break
  alive_or_die
  sleep 0.25
done
[ -n "$IPID" ] || die "iris did not appear in 60 s — tail of $LOG: $(tail -30 "$LOG")"
echo "$IPID" >"$PIDFILE"

if [ "$CAPTURE" = shm ]; then
  # The publisher CREATES this file; it does not exist until the first frame
  # lands, so this wait is "a frame has been published", not "the file grew".
  # THE BUDGET FOLLOWS IRIS_STATE, and getting this wrong looks exactly like a
  # broken publisher: a restore is drawing inside a couple of seconds and 120 s
  # means something is wrong, but a COLD boot draws NOTHING until IRIX has been
  # through PROM and the autoconfig relink and started its X server -- five to
  # seven minutes in which a 120 s watchdog kills a perfectly healthy machine.
  FRAME_TRIES=480
  FRAME_BUDGET="120 s"
  if [ -z "$STATE" ]; then
    FRAME_TRIES=3600
    FRAME_BUDGET="15 min (cold boot)"
  fi
  for _ in $(seq 1 "$FRAME_TRIES"); do
    [ -s "$SHM" ] && break
    alive_or_die
    sleep 0.25
  done
  [ -s "$SHM" ] || die "no frame published to $SHM after $FRAME_BUDGET — the fork's IRIS_SHM_PATH publisher is the only thing that writes it"
else
  XV=""
  for d in /proc/[0-9]*; do
    p="${d#/proc/}"
    [ "$(readlink "/proc/$p/ns/pid" 2>/dev/null)" = "$(readlink "/proc/$IPID/ns/pid" 2>/dev/null)" ] || continue
    case "$(readlink "/proc/$p/exe" 2>/dev/null)" in */Xvfb) XV="$p" ;; esac
  done
  [ -n "$XV" ] && echo "$XV" >"$XPIDFILE"
fi

say "pid=$IPID nspawn=$(cat "$NPIDFILE") uidbase=$UIDBASE capture=$CAPTURE geom=$GEOM ptr=$PTR_MODE state=${STATE:-<none: COLD BOOT, ~7 min through PROM + IRIX autoconfig — the exhibit is degraded until it reaches the login>}"

# A restore that produced a frame has still not proven the guest SERVICES its
# queue — a restored MIPS with a dead i8042 repaints happily and takes no input
# (docs/lab/research/iris-reset-plane.md). Clear the failure ledger only once a
# verb comes back ACKED on the control socket.
if [ -n "$STATE" ]; then kh_reset_confirm 180; fi

# --- standby: freeze once the scene has settled. The daemon owns the steady
# state through SH_IDLE_PAUSE_PIDFILE and SIGCONTs on the first session; without
# a pidfile it cannot freeze a non-QEMU station at all and Iris — the most
# expensive emulator in the lineup, ~320-360 % CPU — burns cores forever.
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${IRIS_STANDBY_DELAY_S:-120}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = "$(readlink -f "$BIN")" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      printf 'iris[%s]: standby — frozen at the scene (pid %s; first session wakes it)\n' "$TILE" "$p"
  ) &
fi
