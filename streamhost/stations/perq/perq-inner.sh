#!/bin/bash
# =============================================================================
# stations/perq/perq-inner.sh — what runs INSIDE the perq station's sandbox.
#
# x11-runtime.sh starts this as PID 2 of a systemd-nspawn container with a
# private PID, mount, network and USER namespace (the container's root is the
# unprivileged host uid range PERQ_UID_BASE+; see the launcher). In here:
# start the pinned Xvfb whose socket directory is bound out to the host for
# the daemon, compose a per-launch PERQemu working directory under /work
# (symlinks to the read-only release tree, a fresh copy of the disk image),
# then exec `mono PERQemu.exe <boot script>` in place — PERQemu's exit ends
# the container, Xvfb included.
#
# GEOMETRY. The PERQ portrait display is 768x1024 (1 bpp). PERQemu shrinks
# its window to SDL's "usable display bounds" minus a 24-line fudge
# (UI/SDL/Display.cs SizeForScreen), so a root exactly 1024 lines tall gets a
# 768x1000 window that PANS. The root is therefore 768x1048: the PERQ screen
# is the top 1024 lines at (0,0), the bottom 24 lines stay black. The daemon
# captures the whole root (capture/x11.rs is full-frame GetImage); a crop knob
# is the open item in docs/lab/PERQ-WAVE.md.
#
# CONSOLE. PERQemu is a console application: its CLI loop polls
# Console.KeyAvailable between SDL/timer ticks. With stdin/stdout not a TTY
# Mono installs the NullConsoleDriver (KeyAvailable is always false), so the
# loop just pumps SDL and the emulator threads forever — exactly what a
# station wants. Never hand it a TTY.
#
# Paths are the container's:
#   $PERQ_ASSETS   the release tree (read-only, bound at /opt/perqemu):
#                  PERQemu.exe + *.dll(+.config), PROM/, Conf/, Resources/, Disks/
#   /work          this launch's writable dir (perq/ working dir, tmp/, logs)
#   /tmp/.X11-unix bound to the host's socket dir (the daemon's door)
# Env from the launcher: PERQ_DISPLAY (:98), PERQ_GEOM (768x1048),
#   PERQ_ASSETS, PERQ_DISK (g7.prqm), PERQ_BOOTCHAR ("" for POS, "z" for Accent)
# =============================================================================
set -euo pipefail
DISP="${PERQ_DISPLAY:?}"
GEOM="${PERQ_GEOM:-768x1048}"
ASSETS="${PERQ_ASSETS:?}"
DISK="${PERQ_DISK:-g7.prqm}"
BOOTCHAR="${PERQ_BOOTCHAR:-}"
WD=/work/perq
log() { echo "$(date -u +%FT%TZ) perq-inner: $*"; }

# The bind-mounted socket dir arrives owned by the host; X wants 1777.
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
rm -f "/tmp/.X11-unix/X${DISP#:}"
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac >/work/xvfb.log 2>&1 &
XPID=$!
for _ in $(seq 1 100); do
  [ -S "/tmp/.X11-unix/X${DISP#:}" ] && break
  kill -0 "$XPID" 2>/dev/null || {
    log "Xvfb died:"
    cat /work/xvfb.log
    exit 1
  }
  sleep 0.1
done
[ -S "/tmp/.X11-unix/X${DISP#:}" ] || {
  log "no X socket after 10 s"
  exit 1
}

# --- the working directory: PERQemu resolves Conf/, PROM/, Resources/ and the
# disk path relative to its cwd, and writes screenshots/logs into Output/.
mkdir -p "$WD/Disks" "$WD/Output" /work/tmp
for f in PERQemu.exe PERQemu.exe.config PacketDotNet.dll SDL2-CS.dll SDL2-CS.dll.config \
  SharpPcap.dll SharpPcap.dll.config Z80dotNet.dll PROM Conf Resources; do
  ln -sfn "$ASSETS/$f" "$WD/$f"
done
[ -f "$ASSETS/Disks/$DISK" ] || {
  log "no disk image $ASSETS/Disks/$DISK"
  exit 1
}
cp --reflink=auto "$ASSETS/Disks/$DISK" "$WD/Disks/$DISK"

# The machine (the same PERQ-1A that runs POS G.7 and Accent S6): 16K CPU,
# 2 MB, CIO + OIO option board (Link, Ether, Tape), portrait display, Kriz
# tablet (ABSOLUTE — PERQemu maps the host pointer onto it 1:1), floppy +
# 14-inch Shugart + QIC tape. `go` powers it on; `bootchar z` selects the
# Accent boot from the shared s6lisp disk.
{
  cat <<CFG
configure
default
name perq
description "PERQ-1A 2MB CIO/OIO portrait, Kriz tablet"
chassis PERQ1
cpu PERQ1A
memory 2048
io board CIO
display Portrait
tablet Kriz
option board OIO
option add Link
option add Ether
option add Tape
drive 0 Floppy
drive 1 Disk14Inch Disks/$DISK
drive 2 Unused
drive 3 TapeQIC
done
CFG
  [ -n "$BOOTCHAR" ] && echo "bootchar $BOOTCHAR"
  echo "go"
} >"$WD/boot.scr"

export DISPLAY="$DISP" HOME=/work TMPDIR=/work/tmp
export SDL_VIDEODRIVER=x11 SDL_RENDER_DRIVER=software SDL_AUDIODRIVER=dummy
export MONO_ENV_OPTIONS="${MONO_ENV_OPTIONS:---gc=sgen}"
unset TERM
cd "$WD"
log "PERQemu on $DISP root $GEOM disk $DISK bootchar '${BOOTCHAR:-none}'"
# stdin: a FIFO held open read-write, so the console NEVER sees EOF. On
# /dev/null the CLI editor wakes on EOF every tick and, with a 0-column
# NullConsoleDriver, spins on "Attempted to divide by zero" (measured
# 2026-09-13); on a quiet pipe KeyAvailable stays false and the loop only
# pumps SDL and the emulator threads.
rm -f /work/console.in
mkfifo /work/console.in
exec 3<>/work/console.in
exec mono "$WD/PERQemu.exe" "$WD/boot.scr" <&3
