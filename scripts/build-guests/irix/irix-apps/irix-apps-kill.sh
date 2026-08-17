#!/usr/bin/env bash
# Tear the Track A install rig down. Kills ONLY by pidfile, through clone-guard
# (which refuses any pidfile outside /data/vms/sandbox or any production QEMU).
# NEVER pkill: the pattern would also match the ssh/bash wrapper.
#
# Prefer a CLEAN shutdown first: irix-apps-cmd.sh exit   (MAME flushes work.chd).
set -u
D="${IRIX_APPS_DIR:-/data/vms/sandbox/irix-apps}"
GUARD=/usr/local/bin/clone-guard

if [ -f "$D/mame.pid" ]; then
  if [ -x "$GUARD" ]; then
    "$GUARD" kill-pidfile "$D/mame.pid" || echo "clone-guard refused $D/mame.pid" >&2
  else
    echo "FATAL: clone-guard missing; refusing to kill by hand" >&2
    exit 1
  fi
fi

# The X server goes through the allocator, which is the guard for displays: it
# signals the pidfile's pid only after proving that pid really holds that
# display, then clears the display's lock/socket/ledger so nobody inherits a
# half-dead :NN.
XVFB_ALLOC_LIB="${XVFB_ALLOC_LIB:-/usr/local/bin/xvfb-alloc}"
[ -f "$XVFB_ALLOC_LIB" ] || XVFB_ALLOC_LIB="$(dirname "$0")/../../../lib/xvfb-alloc.sh"
if [ -f "$D/xvfb.pid" ] && [ -f "$XVFB_ALLOC_LIB" ]; then
  # shellcheck disable=SC1090,SC1091 # resolved at run time (box copy or repo copy)
  source "$XVFB_ALLOC_LIB"
  xvfb_release "$D/xvfb.pid"
fi
rm -f -- "$D/display"
