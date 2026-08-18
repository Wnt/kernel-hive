#!/bin/bash
# qmp-key.sh — send raw QMP sendkey names to a station's guest, then screendump.
# The one-liner form of scripts/dev/qmp-type.py (which does text, mouse and
# clicks); kept because "press Enter, wait 25 s, show me the screen" is the
# whole loop when driving a TUI installer:
#
#   qmp-key.sh <station> <wait-secs> key [key ...]     # e.g. qmp-key.sh hpuxvue 25 y ret
#   QMP=/path/qmp.sock qmp-key.sh - <wait-secs> ret     # a clone/rig socket instead
#   OUT=/data/vms/sandbox/<x> ...                        # where cur.png lands (default /tmp/qmp-type/<station>)
#
# Runs on the box. Prints the PNG path. See docs/lab/simultaneous-OS-install.md §5.
set -euo pipefail
[ $# -ge 2 ] || {
  echo "usage: qmp-key.sh <station|-> <wait-secs> key..." >&2
  exit 2
}
station=$1 wait=$2
shift 2
here="$(cd "$(dirname "$0")" && pwd)"
args=()
if [ "$station" = - ]; then
  [ -n "${QMP:-}" ] || {
    echo "qmp-key.sh: station '-' needs QMP=<socket>" >&2
    exit 2
  }
  args+=(--qmp "$QMP")
else
  args+=(--station "$station")
fi
[ -z "${OUT:-}" ] || args+=(--out "$OUT")
exec python3 "$here/qmp-type.py" "${args[@]}" --wait "$wait" --keys "$@"
