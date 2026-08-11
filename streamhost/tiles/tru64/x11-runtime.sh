#!/bin/bash
# x11-runtime.sh — the tru64 tile launcher (Tru64 UNIX 5.1B on es40).
#
# The THIRD non-QEMU x11-runtime streamhost tile (after IRIX/MAME and
# w2kalpha) and the SIBLING of w2kalpha: the same es40 AlphaServer ES40
# emulator (fork Wnt/es40) with the same headless shape — NO window, NO X
# server (SDL_VIDEODRIVER=dummy), es40 publishes each finished frame into
# $SH_SHM_PATH itself (SH_CAPTURE=shm, src/gui/shmfb.h) and serves mamectl/1
# input on $SH_MAMECTL_SOCK (SH_INPUT_BACKEND=mamesock, src/gui/ctlsock.h,
# MULTI-CLIENT: operator tools may inject beside the attached daemon). What
# differs from w2kalpha is the boot path: this tile's flash.rom carries NO
# arc autoboot script — SRM boots the disk/CD directly (dka0 / dka400).
#
# INSTALL PHASE (current): there is NO golden yet. The guest disk
# $ASSETS/img/tru64.img is the live install target and is mutated IN PLACE —
# this launcher deliberately does NOT copy it. A relaunch therefore REBOOTS
# the machine (SRM console; boot resumes whatever the disk holds) and loses
# only unsynced guest state, not install progress already on disk. After the
# install completes and a golden is captured, this launcher switches to the
# w2kalpha shape: reflink-copy the golden per launch, pristine cold boot.
#
# Installed byte-for-byte as /data/vms/streamhost/tiles/tru64/x11-runtime.sh
# by scripts/streamhost-tile.sh --x11. The shared runtime contract
# (ensure-tile-x11.sh / stop-tile-x11.sh) keys on FIXED pidfile names: the
# emulator pid lives in mame.pid — that is the x11-runtime pidfile name, not
# a claim that es40 is MAME — and liveness under SH_CAPTURE=shm is "mame.pid
# alive AND $SH_SHM_PATH non-empty". Kill ONLY by pidfile.
set -u

D="$(cd "$(dirname "$0")" && pwd)" # tile runtime dir (writable: pidfiles/shm)
ASSETS="${TRU64_ASSETS:-/data/vms/streamhost/assets/tru64}"
ES40="${TRU64_ES40:-$ASSETS/es40}"
LIBROOT="${TRU64_LIBROOT:-$ASSETS/root/usr/lib/x86_64-linux-gnu}"

# tile.env exports SH_SHM_PATH / SH_MAMECTL_SOCK; default them for standalone runs.
SHM="${SH_SHM_PATH:-$D/fb.shm}"
CTL="${SH_MAMECTL_SOCK:-$D/ctl.sock}"
# es40 blocks on startup until BOTH serial ports have a client; pumps.py
# connects them and drains the consoles. The ports es40 LISTENS on come from
# es40.cfg — change them there and here together. The listen bind is the
# tile's atomic claim on the pair (w2kalpha owns 21964/21965; this tile owns
# 21974/21975): a second es40 fails loudly, never silently.
SER0="${TRU64_SER0:-21974}"
SER1="${TRU64_SER1:-21975}"

kill_pidfile() { # $1 = pidfile; kill ONLY the recorded pid, then WAIT for it.
  # The wait matters: an unchecked relaunch raced the dying predecessor's
  # serial listeners once and es40's serial bind fell back to an ephemeral
  # port (unchecked bind() upstream — fixed in the fork, but do not create
  # the race either).
  local pf="$1" p i
  [ -f "$pf" ] || return 0
  p="$(cat "$pf" 2>/dev/null || true)"
  if [ -n "$p" ] && [ -e "/proc/$p" ]; then
    kill -9 "$p" 2>/dev/null || true
    for i in $(seq 1 100); do
      [ -e "/proc/$p" ] || break
      sleep 0.1
    done
  fi
  : >"$pf"
}

# Fresh start: never leave a second es40/pump behind. pumps.py also self-exits
# the moment its es40 sockets die, so a missed pidfile cannot strand one.
kill_pidfile "$D/mame.pid"
kill_pidfile "$D/pumps.pid"

# INSTALL PHASE: run in the asset tree itself — es40.cfg's relative paths
# (img/tru64.img, img/tru64os.iso, rom/flash.rom) resolve against $ASSETS and
# every write (install disk, SRM environment in flash.rom) persists.
cd "$ASSETS" || exit 1
rm -f -- "$SHM" "$CTL"

export LD_LIBRARY_PATH="$LIBROOT"
export SDL_VIDEODRIVER=dummy
export ES40_SHM_PATH="$SHM"
export ES40_CTL_SOCK="$CTL"
export ES40_TILE_NAME=tru64

# setsid detaches from this shell but stays inside ensure-tile-x11.sh's qcap
# scope cgroup, so BindsTo= teardown still reaches everything started here.
setsid nohup "$ES40" >"$D/es40.log" 2>&1 </dev/null &
echo $! >"$D/mame.pid"
setsid nohup python3 "$D/pumps.py" "$SER0" "$SER1" >"$D/pumps.log" 2>&1 </dev/null &
echo $! >"$D/pumps.pid"

sleep 5
P="$(cat "$D/mame.pid")"
if [ ! -e "/proc/$P" ]; then
  echo "es40 FAILED:" >&2
  cat "$D/es40.log" >&2 || true
  exit 1
fi
# The serial pair is the claim — verify both listeners actually belong to our
# es40 before declaring the tile up (a silent fallback here wedges the boot).
for port in "$SER0" "$SER1"; do
  ok=0
  for i in $(seq 1 20); do
    if ss -ltnp 2>/dev/null | grep -q ":$port .*pid=$P,"; then
      ok=1
      break
    fi
    sleep 0.5
  done
  if [ "$ok" != 1 ]; then
    echo "es40 serial port $port not bound by pid $P — refusing to continue:" >&2
    ss -ltnp 2>/dev/null | grep ":$port " >&2 || echo "(no listener at all)" >&2
    exit 1
  fi
done
echo "tru64 runtime up: es40 pid=$P pumps=$(cat "$D/pumps.pid") shm=$SHM ctl=$CTL (install phase: persistent disk, SRM boot)"
