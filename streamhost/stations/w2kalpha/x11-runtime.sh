#!/bin/bash
# x11-runtime.sh — the w2kalpha tile launcher (Windows 2000 RC2 for Alpha).
#
# The SECOND non-QEMU x11-runtime streamhost tile (after IRIX/MAME): instead of
# a QEMU/dbus display it runs Windows 2000 RC2 (build 2128, Alpha AXP) inside
# the es40 AlphaServer ES40 emulator (fork Wnt/es40) with NO window and NO X
# server (SDL_VIDEODRIVER=dummy). es40 publishes each finished frame into
# $SH_SHM_PATH itself (SH_CAPTURE=shm, src/gui/shmfb.h) and serves mamectl/1
# input on $SH_MAMECTL_SOCK (SH_INPUT_BACKEND=mamesock, src/gui/ctlsock.h).
#
# Installed byte-for-byte as /data/vms/streamhost/stations/w2kalpha/x11-runtime.sh
# by scripts/streamhost-station.sh --x11. The shared runtime contract
# (ensure-station-x11.sh / stop-station-x11.sh) keys on FIXED pidfile names: the
# emulator pid lives in mame.pid — that is the x11-runtime pidfile name, not a
# claim that es40 is MAME — and liveness under SH_CAPTURE=shm is "mame.pid
# alive AND $SH_SHM_PATH non-empty". Kill ONLY by pidfile.
#
# resetMode=relaunch: every launch reflink-copies the golden nt.img, so each
# boot is pristine (~80 s to desktop). es40's savestate restore is NOT used —
# a restored guest partial-paints new dialogs (post-restore repaint fragility,
# docs/lab/research/w2kalpha-HANDOFF.md); cold boot renders everything.
#
# The defaults are the PRODUCTION asset tree /data/vms/streamhost/assets/
# w2kalpha. NEVER point a live tile at /data/vms/soltest (agent scratch that
# gets rebuilt/deleted under a running exhibit).
set -u

D="$(cd "$(dirname "$0")" && pwd)" # tile runtime dir (writable: pidfiles/work/shm)
ASSETS="${W2KALPHA_ASSETS:-/data/vms/streamhost/assets/w2kalpha}"
ES40="${W2KALPHA_ES40:-$ASSETS/es40}"
GOLDEN="${W2KALPHA_GOLDEN:-$ASSETS/nt.img}" # clean 1280x1024 cold-boot disk (m5-1280 lineage)
LIBROOT="${W2KALPHA_LIBROOT:-$ASSETS/root/usr/lib/x86_64-linux-gnu}"

# station.env exports SH_SHM_PATH / SH_MAMECTL_SOCK; default them for standalone runs.
SHM="${SH_SHM_PATH:-$D/fb.shm}"
CTL="${SH_MAMECTL_SOCK:-$D/ctl.sock}"
# es40 blocks on startup until BOTH serial ports have a client; pumps.py
# connects them and drains the consoles. The ports es40 LISTENS on come from
# es40.cfg — change them there and here together. The listen bind is the
# tile's atomic claim on the pair: a second es40 fails loudly, never silently.
SER0="${W2KALPHA_SER0:-21964}"
SER1="${W2KALPHA_SER1:-21965}"

kill_pidfile() { # $1 = pidfile; kill ONLY the recorded pid
  local pf="$1" p
  [ -f "$pf" ] || return 0
  p="$(cat "$pf" 2>/dev/null || true)"
  if [ -n "$p" ] && [ -e "/proc/$p" ]; then kill -9 "$p" 2>/dev/null || true; fi
  : >"$pf"
}

# Fresh start: never leave a second es40/pump behind. pumps.py also self-exits
# the moment its es40 sockets die, so a missed pidfile cannot strand one.
kill_pidfile "$D/mame.pid"
kill_pidfile "$D/pumps.pid"

# Per-launch pristine state: throwaway work dir + reflink golden copy (COW on
# ZFS — instant; --sparse keeps the fallback cheap). The guest writes to the
# copy only; the golden is never opened for write.
WORK="$D/work"
rm -rf "$WORK"
mkdir -p "$WORK/img" "$WORK/rom"
cp --reflink=auto --sparse=always "$GOLDEN" "$WORK/img/nt.img"
ln -sf "$ASSETS/w2k.iso" "$WORK/img/w2k.iso"
cp "$ASSETS/rom/"* "$WORK/rom/"
cp "$ASSETS/es40.cfg" "$WORK/es40.cfg"

cd "$WORK" || exit 1
rm -f -- "$SHM" "$CTL"

export LD_LIBRARY_PATH="$LIBROOT"
export SDL_VIDEODRIVER=dummy
export ES40_SHM_PATH="$SHM"
export ES40_CTL_SOCK="$CTL"

# Host-only guest network for the telnet exec channel (labctl exec w2kalpha).
# es40.cfg's dec21143 uses the pcap backend on the GUEST end of a veth pair; the
# guest holds a static IP (172.31.64.2/30) baked into the golden, and the host
# answers on 172.31.64.1. Creating the pair is this tile's atomic claim on the
# name — a second launcher for the same tile cannot duplicate it — and it is
# idempotent across relaunches (reuse if present). Host-only by construction:
# nothing bridges w2kalpha-h to the LAN, so the guest's telnet server (blank
# Administrator, NTLM off) is reachable ONLY from this box, never off-host.
NIC_H=w2kalpha-h
NIC_G=w2kalpha-g
if ! ip link show "$NIC_G" >/dev/null 2>&1; then
  ip link add "$NIC_H" type veth peer name "$NIC_G" ||
    {
      echo "veth claim failed for $NIC_H/$NIC_G" >&2
      exit 1
    }
fi
ip addr replace 172.31.64.1/30 dev "$NIC_H"
ip link set "$NIC_H" up
ip link set "$NIC_G" up
# veth TX checksum offload leaves locally-originated packets with unfilled
# checksums, which es40's pcap capture then sees as corrupt; disable on both ends.
ethtool -K "$NIC_H" tx off rx off >/dev/null 2>&1 || true
ethtool -K "$NIC_G" tx off rx off >/dev/null 2>&1 || true

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
echo "w2kalpha runtime up: es40 pid=$P pumps=$(cat "$D/pumps.pid") shm=$SHM ctl=$CTL boot=cold (~80 s to desktop)"
