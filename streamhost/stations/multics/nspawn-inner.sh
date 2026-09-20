#!/bin/bash
# =============================================================================
# stations/multics/nspawn-inner.sh — PID 2 INSIDE the multics container.
#
# Multics MR12.8 on an emulated Honeywell/Bull DPS-8/M under the DPS8M
# simulator R3.1.0 (dps8m.gitlab.io, pinned in assets/multics/MANIFEST.sha256).
# No QEMU, no MAME and no checkpoint: the exhibit is a simulator process plus
# one terminal, and reset = relaunch from the pristine baked root.dsk.
#
# This script is only the STATION PROLOGUE. It stages the writable disk, writes
# the simulator's ini file and then execs the lane's shared engine,
# docs/lab/record-wave/shared-terminal-runtime.sh, which owns Xvfb, the hidden
# emulator, the two-condition readiness gate and the visitor client.
#
# Writable state is /work only. The outer launcher reflink-copied the pristine
# root.dsk there before this script ran (MEASURED 0.126 s for 594 MB on
# labhost's ZFS — a pristine per-launch copy is free, which is exactly why this
# station has no checkpoint). The baked disk in assets/media is bound
# read-only, so nothing a visitor types can reach it.
#
# The FNP telnet listener on 6180 is the visitor line. It lives on the
# container's own loopback behind --private-network, so it needs no host port
# claim and is unreachable from labhost.
# =============================================================================
set -euo pipefail

WORK=/work
ASSETS="${MULTICS_ASSETS:?MULTICS_ASSETS required}"
PORT="${MULTICS_PORT:-6180}"
COLS="${MULTICS_COLS:-80}"
ROWS="${MULTICS_ROWS:-24}"
FONTSIZE="${MULTICS_FONTSIZE:-14}"
XOFF="${MULTICS_XOFF:-+32+96}"

[ -f "$WORK/root.dsk" ] || {
  echo "multics-inner: no writable disk at $WORK/root.dsk (outer launcher did not seed work/)" >&2
  exit 1
}

# --- the simulator config. Written here, not taken from the read-only assets,
# because it attaches the WORK copy of the disk while the tape stays read-only
# in assets/media.
#
# The `autoinput` block is the stock QuickStart MR12.8 boot answer sheet,
# verbatim: it answers find_rpv_subsystem's RPV data prompt, BCE's `bce`
# request, the time-of-day confirmation, the boot_delta warning (the baked disk
# WAS shut down cleanly, so its RPV label carries an unmounted time and the
# warning is expected and correct), and finally `boot star` to bring up the
# answering service. `\z` closes the autoinput stream so that the operator
# console is free for the visitor's system afterwards.
#
# Device set, frozen for the first release (docs/lab/MULTICS-WAVE.md):
#   disk0  the work copy of the MR12.8 RPV
#   tape0  12.8MULTICS.tap, read-only (the MR12.8 system tape)
#   fnp3   FNP D, telnet listener on $PORT — channel d.h000 is the visitor line
#   no Ethernet, no other channel — this station is an island on purpose
cat >"$WORK/boot.ini" <<CONF
attach -r tape0 $ASSETS/media/12.8MULTICS.tap
attach disk0 $WORK/root.dsk
clrautoinput

autoinput rpv a11 ipc 3381 0a\n
autoinput bce\n
autoinput yes\n
autoinput yes\n
autoinput boot star\n
autoinput \z

boot iom0
CONF

# The museum surface: one xterm on the FNP line. `telnet -E` is deliberate: it
# drops one line of chrome AND removes the `^]` escape, so a visitor cannot
# fall out of the exhibit into a telnet command prompt.
#
# No window manager runs, so xterm maps itself at exactly this size and offset
# and the rest of the root window stays black. 80x24 is what Multics' own
# default line type assumes; the FNP carries no window-size negotiation, so
# anything else makes full-screen output wrap wrong.
export KH_TERM_DISPLAY="${SH_X11_DISPLAY:?}"
export KH_TERM_GEOM="${MULTICS_GEOM:-1024x768}"
export KH_TERM_WORK="$WORK"
export KH_TERM_EMULATOR_CWD="$WORK"
# FINDING 2 (this station proved it): `dps8 ... < fifo` prints as far as the
# FNP listen line and then sleeps forever — no CPU thread, no boot. /dev/null
# boots. Nothing drives this console once the autoinput sheet is spent, so
# /dev/null is the right answer and no pty supervisor is needed.
export KH_TERM_EMULATOR_STDIN=/dev/null
export KH_TERM_EMULATOR_CMD="$ASSETS/bin/dps8 $WORK/boot.ini"
export KH_TERM_READY_PORT="$PORT"
# FINDING 1 (this station is the sharpest case): TCP/6180 opens at +4 s and the
# answering service is not up for another 48 s. The port is a precondition; the
# gate is the simulator's own console stream printing
# `as_init_: Multics MR12.8; Answering Service 17.0`.
export KH_TERM_READY_LOG_RE='as_init_'
export KH_TERM_READY_TIMEOUT_S="${MULTICS_READY_TIMEOUT_S:-420}"
export KH_TERM_CLIENT_CMD="exec xterm -display '${SH_X11_DISPLAY}' \
-geometry '${COLS}x${ROWS}${XOFF}' \
-fa 'DejaVu Sans Mono' -fs '${FONTSIZE}' \
-bg black -fg '#ffb000' -cr '#ffb000' -b 0 -bw 0 +sb \
-title 'Multics console' -xrm 'xterm*backarrowKey: false' \
-xrm 'xterm*metaSendsEscape: true' \
-e telnet -E 127.0.0.1 ${PORT}"

exec "$WORK/shared-terminal-runtime.sh"
