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
# SEED PHASE (since 2026-08-16): the install is done and this launcher runs
# the w2kalpha shape — every launch reflink-copies $ASSETS/img/tru64-seed.img
# into a throwaway work dir, so each boot is pristine and the seed is never
# opened for write. The guest auto-logs into CDE (dtlogin's autoLogin
# resource in /etc/dt/config/Xconfig + passwordless root), so a cold boot
# lands on the desktop with no greeter — the Tru64 equivalent of w2kalpha's
# Windows autologon. The install-era disk img/tru64.img is retained as the
# seed's lineage; nothing reads it at runtime.
#
# Installed byte-for-byte as /data/vms/streamhost/stations/tru64/x11-runtime.sh
# by scripts/streamhost-station.sh --x11. The shared runtime contract
# (ensure-station-x11.sh / stop-station-x11.sh) keys on FIXED pidfile names: the
# emulator pid lives in mame.pid — that is the x11-runtime pidfile name, not
# a claim that es40 is MAME — and liveness under SH_CAPTURE=shm is "mame.pid
# alive AND $SH_SHM_PATH non-empty". Kill ONLY by pidfile.
set -u

D="$(cd "$(dirname "$0")" && pwd)" # tile runtime dir (writable: pidfiles/shm)
ASSETS="${TRU64_ASSETS:-/data/vms/streamhost/assets/tru64}"
ES40="${TRU64_ES40:-$ASSETS/es40}"
LIBROOT="${TRU64_LIBROOT:-$ASSETS/root/usr/lib/x86_64-linux-gnu}"

# station.env exports SH_SHM_PATH / SH_MAMECTL_SOCK; default them for standalone runs.
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

# Per-launch pristine state, the w2kalpha shape: throwaway work dir + reflink
# seed copy (COW on ZFS — instant; --sparse keeps the fallback cheap). The
# guest writes to the copy only; the seed is never opened for write, so every
# launch is the same cold boot into the autologin CDE desktop.
#
# The install phase (2026-08-11/12) ran in the asset tree itself and mutated
# img/tru64.img in place; that disk — cleanly halted, autologin configured —
# IS the lineage of img/tru64-seed.img. Set TRU64_SEED to pin a different one.
# es40.cfg's paths are relative, so they resolve against $WORK here.
SEED="${TRU64_SEED:-$ASSETS/img/tru64-seed.img}"
[ -f "$SEED" ] || {
  echo "FATAL: tru64 seed missing: $SEED" >&2
  exit 1
}
WORK="$D/work"
rm -rf "$WORK"
mkdir -p "$WORK/img" "$WORK/rom"
cp --reflink=auto --sparse=always "$SEED" "$WORK/img/tru64.img"
ln -sf "$ASSETS/img/tru64os.iso" "$WORK/img/tru64os.iso"
cp "$ASSETS/rom/"* "$WORK/rom/"
cp "$ASSETS/es40.cfg" "$WORK/es40.cfg"

cd "$WORK" || exit 1
rm -f -- "$SHM" "$CTL"

export LD_LIBRARY_PATH="$LIBROOT"
export SDL_VIDEODRIVER=dummy
export ES40_SHM_PATH="$SHM"
export ES40_CTL_SOCK="$CTL"
export ES40_TILE_NAME=tru64

# setsid detaches from this shell but stays inside ensure-station-x11.sh's qcap
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
