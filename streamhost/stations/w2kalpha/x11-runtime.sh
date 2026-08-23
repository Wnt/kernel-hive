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
# resetMode=relaunch, restored from the golden CHECKPOINT: every launch
# reflink-copies the golden nt.img AND hands es40 the golden.axp savestate
# baked from that exact image (ES40_RESTORE), so each launch is the same
# pristine desktop ~3 s after exec instead of an ~80 s cold boot. The pair is
# atomic by construction (serial-menu option 5 = save-and-exit: no guest write
# can land between the state file and the image), and the guest only ever
# writes to the per-launch copy, so the pair stays coherent forever.
#
# Drop golden.axp out of the asset tree and this falls back to a cold boot on
# its own — that is the rollback, and it needs no edit here.
#
# The defaults are the PRODUCTION asset tree /data/vms/streamhost/assets/
# w2kalpha. NEVER point a live tile at /data/vms/sandbox (agent scratch that
# gets rebuilt/deleted under a running exhibit).
set -u

D="$(cd "$(dirname "$0")" && pwd)" # tile runtime dir (writable: pidfiles/work/shm)
ASSETS="${W2KALPHA_ASSETS:-/data/vms/streamhost/assets/w2kalpha}"
ES40="${W2KALPHA_ES40:-$ASSETS/es40}"
GOLDEN="${W2KALPHA_GOLDEN:-$ASSETS/nt.img}"             # clean 1280x1024 disk (m5-1280 lineage)
GOLDEN_AXP="${W2KALPHA_GOLDEN_AXP:-$ASSETS/golden.axp}" # savestate BAKED FROM THAT IMAGE
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

kill_pidfile() { # $1 = pidfile; kill ONLY the recorded pid, then WAIT for it.
  # The wait matters: resetMode=relaunch restarts THIS station on top of its own
  # dying predecessor, and es40 re-binds the two serial listen ports
  # (21964/21965) the instant it starts. Without waiting for the old es40 to
  # actually leave /proc, the fresh launch races it for those ports and es40's
  # serial bind can fall back to an ephemeral port — a silent wedge, since
  # pumps.py then drains the wrong port and the guest blocks on startup (es40
  # holds until BOTH consoles have a client). Kill, then poll until gone.
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
export ES40_TILE_NAME=w2kalpha # names this es40 in the mamectl HELLO banner

# Instant resume from the checkpoint. es40 restores the state file BEFORE its
# main loop and skips the SRM decompress entirely when it can read one (that
# decompress is the ~30 s the old cold boot spent inflating a console the
# restore overwrites anyway). An absent or unreadable file cold-boots instead,
# so this is safe to have unconditionally.
BOOT="cold (~80 s to desktop)"
if [ -f "$GOLDEN_AXP" ]; then
  cp --reflink=auto "$GOLDEN_AXP" "$WORK/golden.axp"
  export ES40_RESTORE="$WORK/golden.axp"
  BOOT="restore from golden.axp (~3 s to desktop)"
fi

# Guest network: the OFFLINE retronet bridge vmbr-rn, via this station's own
# rn-tapnet.sh. es40.cfg's dec21143 uses the pcap backend on the GUEST end of a
# veth pair (w2kalpha-g); rn-tapnet.sh enslaves the HOST end (w2kalpha-h) to
# vmbr-rn, so the guest is a retronet host on DHCP (reserved 10.99.0.17, DNS
# 10.99.0.2, NO default route) sharing real L2 with the gateway CT (10.99.0.2)
# for the corpus web on :80 — while a fail-closed guard chain (W2KALPHARN-IN,
# scoped to 10.99.0.17) drops every NEW flow the guest starts toward labhost.
# The telnet exec channel (labctl exec w2kalpha, blank Administrator/NTLM off)
# rides the new address: labhost dials 10.99.0.17:23 and the guest only ever
# REPLIES toward labhost (ESTABLISHED, allowed). This REPLACED the pre-retronet
# HOST-ONLY wiring (a 172.31.64.1/30 address on w2kalpha-h, guest static
# 172.31.64.2); rn-tapnet.sh `up` also tears that down. It MUST run before es40
# (pcap opens w2kalpha-g at boot) and is fail-closed: if the containment chain
# does not verify, es40 never starts.
"$D/rn-tapnet.sh" up || {
  echo "w2kalpha rn-tapnet up failed — refusing to start es40" >&2
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
# The serial pair (21964/21965) is this tile's atomic claim: es40 binds both at
# startup and pumps.py drains them. Verify BOTH listeners actually belong to our
# es40 before declaring the tile up — if a relaunch raced its dying predecessor
# and es40 fell back to an ephemeral serial port, the guest wedges at startup
# (es40 blocks until both consoles have a client) and a silent "up" would hide
# it until the first visitor met a black screen.
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
echo "w2kalpha runtime up: es40 pid=$P pumps=$(cat "$D/pumps.pid") shm=$SHM ctl=$CTL boot=$BOOT"
