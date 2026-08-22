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
# CHECKPOINT PHASE (since 2026-08-16): the install is done and this launcher
# runs the w2kalpha shape — every launch reflink-copies a read-only disk into
# a throwaway work dir, so each launch is pristine. With a checkpoint staged
# (assets/tru64/checkpoint/) it RESTORES an es40 savestate and lands the CDE
# desktop in ~5 s; without one it cold-boots the seed the long way (~7-10 min).
# The guest auto-logs into CDE (dtlogin's autoLogin resource in
# /etc/dt/config/Xconfig + passwordless root), so even the cold path needs no
# greeter — the Tru64 equivalent of w2kalpha's Windows autologon. The
# install-era disk img/tru64.img is retained as the seed's lineage; nothing
# reads it at runtime.
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
# disk copy (COW on ZFS — instant; --sparse keeps the fallback cheap). The
# guest writes to the copy only; the source image is never opened for write.
#
# WHICH disk depends on whether a CHECKPOINT is staged:
#
#   checkpoint/{tru64.axp,tru64.img}  ->  restore. The savestate and the disk
#     it was baked from are a PAIR (serial-menu option 5 = save-and-exit, so no
#     guest write can land between them); es40 restores the memory image before
#     its main loop and skips the SRM decompress, landing the CDE desktop in
#     ~5 s. checkpoint/rom is part of the pair too — dpr.rom/flash.rom carry
#     state that es40 rewrites on exit.
#
#   otherwise                          ->  cold boot from img/tru64-seed.img,
#     the ~7-10 min SRM -> rc -> CDE autologin path this station shipped with.
#
# Deleting the checkpoint dir is therefore the whole rollback, and it needs no
# edit here. The install phase (2026-08-11/12) ran in the asset tree itself and
# mutated img/tru64.img in place; that disk — cleanly halted, autologin
# configured — IS the lineage of img/tru64-seed.img. TRU64_SEED /
# TRU64_CHECKPOINT pin different ones. es40.cfg's paths are relative, so they
# resolve against $WORK here.
SEED="${TRU64_SEED:-$ASSETS/img/tru64-seed.img}"
CKPT="${TRU64_CHECKPOINT:-$ASSETS/checkpoint}"
if [ -f "$CKPT/tru64.axp" ] && [ -f "$CKPT/tru64.img" ]; then
  DISK="$CKPT/tru64.img"
  BOOT="restore from checkpoint (~5 s to the CDE desktop)"
else
  DISK="$SEED"
  BOOT="cold boot from the seed (~7-10 min to the CDE desktop)"
fi
[ -f "$DISK" ] || {
  echo "FATAL: tru64 disk missing: $DISK" >&2
  exit 1
}
WORK="$D/work"
rm -rf "$WORK"
mkdir -p "$WORK/img" "$WORK/rom"
cp --reflink=auto --sparse=always "$DISK" "$WORK/img/tru64.img"
ln -sf "$ASSETS/img/tru64os.iso" "$WORK/img/tru64os.iso"
if [ -d "$CKPT/rom" ] && [ "$DISK" = "$CKPT/tru64.img" ]; then
  cp "$CKPT/rom/"* "$WORK/rom/"
else
  cp "$ASSETS/rom/"* "$WORK/rom/"
fi
cp "$ASSETS/es40.cfg" "$WORK/es40.cfg"

cd "$WORK" || exit 1
rm -f -- "$SHM" "$CTL"

export LD_LIBRARY_PATH="$LIBROOT"
export SDL_VIDEODRIVER=dummy
export ES40_SHM_PATH="$SHM"
export ES40_CTL_SOCK="$CTL"
export ES40_TILE_NAME=tru64
# This guest's X pointer stack moves TWO screen pixels per injected PS/2 count
# (measured against XQueryPointer: 10/25/50/100/200 counts -> 20/50/100/200/400
# px, with X acceleration already flat at 1/1, so it is not acceleration).
# Without this the daemon's absolute pointer lands at twice the intended delta
# and clamps at the screen edge; with it, MOVEA is pixel-exact on even
# coordinates and 1 px short on odd ones (a count cannot express one pixel).
export ES40_POINTER_GAIN=2
if [ "$DISK" = "$CKPT/tru64.img" ]; then
  cp --reflink=auto "$CKPT/tru64.axp" "$WORK/checkpoint.axp"
  export ES40_RESTORE="$WORK/checkpoint.axp"
fi

# Guest network: the OFFLINE retronet bridge vmbr-rn, via rn-tapnet.sh (the
# es40 sibling of the QEMU stations' rn-tapnet.sh — a veth PAIR because es40
# captures a host interface with pcap rather than attaching a tap). es40 opens
# the GUEST end (tru64-g, es40.cfg `adapter =`) with pcap; rn-tapnet.sh enslaves
# the HOST end (tru64-h) to vmbr-rn, so the guest shares real L2 with the
# gateway CT (10.99.0.2) for its Gaim/OSCAR ICQ client — while a fail-closed
# guard chain (TRU64RN-IN, scoped to the guest's static 10.99.0.15) drops every
# NEW flow the guest starts toward labhost. This REPLACED the pre-2026-08-21 WAN
# wiring (172.31.66.0/30 MASQUERADE, the one station with a real internet path);
# rn-tapnet.sh `up` also tears that down. It MUST run before es40 (pcap opens
# tru64-g at boot) and is fail-closed: if the containment chain does not verify,
# es40 never starts.
"$D/rn-tapnet.sh" up || {
  echo "tru64 rn-tapnet up failed — refusing to start es40" >&2
  exit 1
}

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
echo "tru64 runtime up: es40 pid=$P pumps=$(cat "$D/pumps.pid") shm=$SHM ctl=$CTL boot=$BOOT"
