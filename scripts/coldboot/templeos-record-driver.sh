#!/bin/bash
# Answer TempleOS's two ISO first-boot questions on a clone, with no human input.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bootrec-lib.sh disable=SC1091
source "${BOOTREC_LIB:-$HERE/bootrec-lib.sh}"
QMP="${1:?qmp.sock required}"
WORK="${2:?workdir required}/templeos-driver"
mkdir -p "$WORK"

# "Install onto hard drive?" then "Take Tour?". Both default flows are unsafe
# for a recorder, so explicitly answer no after conservative rendering holds.
sleep 10
br_screendump "$QMP" "$WORK/install-question.png" || br_die "templeos driver: no install-question framebuffer"
br_hmp "$QMP" 'sendkey n' >/dev/null
sleep 8
br_screendump "$QMP" "$WORK/tour-question.png" || br_die "templeos driver: no tour-question framebuffer"
br_hmp "$QMP" 'sendkey n' >/dev/null
sleep 10
br_screendump "$QMP" "$WORK/ready.png" || br_die "templeos driver: no final framebuffer"
