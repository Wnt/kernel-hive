#!/bin/bash
# =============================================================================
# stations/its/nspawn-inner.sh — PID 2 INSIDE the its container.
#
# MIT ITS (the Incompatible Timesharing System, MIT AI Lab, 1967) on an
# emulated DEC PDP-10 (KS10) under SIMH, built from source by the maintained
# github.com/PDP-10/its tree. No QEMU, no MAME and no checkpoint: the exhibit
# is a simulator process plus one terminal, and reset = relaunch from the
# pristine built disk.
#
# This script is only the STATION PROLOGUE. It checks the writable disk the
# outer launcher staged, writes the simulator's ini file and then execs the
# lane's shared engine, shared-terminal-runtime.sh (proven end to end by
# vax43bsd), which owns Xvfb, the hidden emulator, the two-condition readiness
# gate and the visitor client.
#
# Writable state is /work only. The outer launcher copied the pristine rp0.dsk
# there before this script ran, and the ini below attaches THAT copy — the
# built tree is bound read-only, so a visitor who reaches DDT (ITS has no
# protection between users; that is the exhibit) can never touch the seed.
#
# The DZ11 line 0 telnet listener is the visitor line. It lives on the
# container's own loopback behind --private-network, so it needs no host port
# claim and is unreachable from labhost.
# =============================================================================
set -euo pipefail

WORK=/work
TREE="${ITS_TREE:?ITS_TREE required}"
PORT="${ITS_PORT:-10004}"
COLS="${ITS_COLS:-80}"
ROWS="${ITS_ROWS:-30}"
FONTSIZE="${ITS_FONTSIZE:-21}"
XOFF="${ITS_XOFF:-+0+0}"

[ -f "$WORK/rp0.dsk" ] || {
  echo "its-inner: no writable disk at $WORK/rp0.dsk (outer launcher did not seed work/)" >&2
  exit 1
}

# --- the simulator config. Written here, not taken from the read-only tree,
# because the tree's own out/simh/boot attaches the SEED disk by a relative
# path; this one attaches the WORK copy and the per-launch DZ port.
#
# Device set, frozen for the first release (docs/lab/ITS-WAVE.md):
#   rp0  RP06, the work copy of the built ITS disk — the whole system
#   dz   DZ11, 8 lines, 8-bit; line 0 is the visitor terminal
#   everything else left at the generated config's defaults; no Chaosnet, no
#   GT40 and no second VT52 — this station publishes exactly ONE terminal.
#
# The `expect` rule is finding 3 of the shared runtime: SIMH answers for
# itself from the ini file, so no pty/expect supervisor sits between the
# container's init and the simulator, and it hands finding 1 its readiness
# token for free. ITS_READY_CONSOLE_RE is what the simulator waits to see on
# the PDP-10's own console before it echoes the token.
cat >"$WORK/boot" <<CONF
set console wru=034
set cpu its
set cpu idle
set tim y2k
set dz 8b lines=8
at -u dz0 $PORT
set rp0 rp06
at rp0 $WORK/rp0.dsk
expect "${ITS_READY_CONSOLE_RE:-\$}" echo KHBOOTREADY; go
b rp0
CONF

# The museum surface: one xterm on the DZ line. `telnet -E` is deliberate —
# it drops a line of chrome AND removes the `^]` escape, so a visitor cannot
# fall out of the exhibit into a telnet command prompt. `^\` is likewise not
# offered on the on-screen keyboard: it would reach the SIMH `sim>` prompt.
export KH_TERM_DISPLAY="${SH_X11_DISPLAY:?}"
export KH_TERM_GEOM="${ITS_GEOM:-1024x768}"
export KH_TERM_WORK="$WORK"
export KH_TERM_EMULATOR_CWD="$WORK"
export KH_TERM_EMULATOR_STDIN=/dev/null
export KH_TERM_EMULATOR_CMD="$TREE/tools/simh/BIN/pdp10 $WORK/boot"
export KH_TERM_READY_PORT="$PORT"
export KH_TERM_READY_LOG_RE="${ITS_READY_LOG_RE:-KHBOOTREADY}"
export KH_TERM_READY_TIMEOUT_S="${ITS_READY_TIMEOUT_S:-300}"
export KH_TERM_CLIENT_CMD="exec xterm -display '${SH_X11_DISPLAY}' \
-geometry '${COLS}x${ROWS}${XOFF}' \
-fa 'DejaVu Sans Mono' -fs '${FONTSIZE}' \
-bg black -fg white -cr white -b 0 -bw 0 +sb \
-title 'MIT ITS' -xrm 'xterm*backarrowKey: false' \
-xrm 'xterm*metaSendsEscape: true' \
-e telnet -E 127.0.0.1 ${PORT}"

exec "$WORK/shared-terminal-runtime.sh"
