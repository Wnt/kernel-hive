#!/usr/bin/env bash
# irix-retronet-install.sh — push irix-net-retronet-bake.sh into a BOOTED IRIX
# clone over the guest's own console getty, run it, and show the result.
#
#   irix-serial-rig.sh boot rnbake --chd irix65-apps-v9.chd --console \
#       (with IRIX_RIG_TAP_IF=<a tap on vmbr-rn>)      # ~6 min cold boot
#   irix-retronet-install.sh rnbake                    # ~1 min
#   irix-serial-rig.sh exec rnbake "netstat -rn"       # REAL captured stdout
#   irix-serial-rig.sh halt rnbake                     # clean shutdown
#   # -> <rig>/rnbake/disk.chd is the next seed
#
# Sibling of irix-serial-install.sh, and the console mechanics below (login
# order, echo off, the quoted here-document, the 0.18 s line delay) are ITS
# hard-won sequence — read that file's comments before changing any of it.
# The difference is only what gets pushed and that this one RUNS what it pushed.
#
# Runs ON labhost. Touches only <rig>/<name>.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RIG="${IRIX_SERIAL_RIG:-$HERE/irix-serial-rig.sh}"
BAKE="${IRIX_RETRONET_BAKE:-$HERE/irix-net-retronet-bake.sh}"
ROOT="${IRIX_SERIAL_ROOT:-/data/vms/sandbox/irix-serial}"
LINE_DELAY="${IRIX_INSTALL_LINE_DELAY:-0.18}"
DST="${IRIX_RETRONET_DST:-/tmp/rn-bake.sh}"

NAME="${1:-}"
[ -n "$NAME" ] || {
  echo "usage: irix-retronet-install.sh <clone-name>" >&2
  exit 2
}
D="$ROOT/$NAME"
[ -d "$D" ] || {
  echo "no such clone: $D" >&2
  exit 2
}
[ -f "$BAKE" ] || {
  echo "no bake script: $BAKE" >&2
  exit 2
}

log() { echo "$(date '+%F %T') $*"; }
die() {
  echo "irix-retronet-install: $*" >&2
  exit 1
}

PTS_CONSOLE="$("$RIG" pts "$NAME" | sed -n 2p)"
[ -n "$PTS_CONSOLE" ] || die "no console pty — boot the clone with --console"
log "console line: $PTS_CONSOLE"

say() {
  printf '%s\r' "$1" >"$PTS_CONSOLE"
  sleep "$LINE_DELAY"
}
push() {
  local src="$1" dst="$2" line
  say "cat > $dst <<'RNBAKE_EOF'"
  while IFS= read -r line; do say "$line"; done <"$src"
  say "RNBAKE_EOF"
}

# ---- 1. log in and get a quiet, non-echoing Bourne shell --------------------
# Verbatim from irix-serial-install.sh — see there for why each step exists
# (the TERM prompt eating a line, csh's history expansion, echo off last, and
# nothing typed before `root`). Assumes a FRESH boot sitting at `login:`.
if [ "${IRIX_INSTALL_SKIP_LOGIN:-0}" = 1 ]; then
  log "skipping login (IRIX_INSTALL_SKIP_LOGIN=1)"
  say "RNBAKE_EOF"
  say "stty -echo -ixon -ixoff -istrip"
  sleep 1
else
  log "logging in on the console"
  say ""
  sleep 2
  say "root" # empty password, so login(1) never prompts for one
  sleep 5
  say ""
  sleep 2
  say "exec /bin/sh"
  sleep 2
  say "stty -echo -ixon -ixoff -istrip"
  sleep 2
  say "RNBAKE_EOF" # closes a here-document left open by an aborted run
fi

# ---- 2. push and run --------------------------------------------------------
log "pushing $(basename "$BAKE") ($(wc -l <"$BAKE") lines) to $DST"
push "$BAKE" "$DST"
say "chmod 755 $DST"
sleep 1
# Run it with output on the AGENT line, not the console: guest->host on the
# console is not byte-clean (irix-serial-install.sh), and the agent gives real
# captured stdout. The console only ever has to carry the bytes IN.
log "running the bake (output captured through the agent channel)"
say "sh $DST > /tmp/rn-bake.out 2>&1"
sleep 8
"$RIG" exec "$NAME" "cat /tmp/rn-bake.out" || die "could not read the bake output"

log "restarting the guest's network with the new config"
# /etc/init.d/network stop+start re-reads /etc/hosts, ifconfig-1.options and the
# (now absent) static-route.options — the same path a reboot takes, without the
# six minutes. The address change means the agent line is unaffected: exec is
# serial, not network, which is exactly why it still answers afterwards.
"$RIG" exec "$NAME" "/etc/init.d/network stop; /etc/init.d/network start; sleep 2; netstat -in; netstat -rn" ||
  die "network restart did not report back"
log "done — verify from the host, then halt the clone to promote its disk.chd"
