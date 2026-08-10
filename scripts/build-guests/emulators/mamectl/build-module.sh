#!/bin/bash
# Build the ctlsock module ON THE BOX, in the pinned trixie chroot: apply the
# full patch stack, build, and restore the tree unconditionally -- a failed
# chain that leaves the stack applied poisons the next run with "TREE NOT
# PRISTINE".
#
#   build-module.sh [output-binary]
#
# Regenerate mame-ctlsock.patch from src/ with regen-patch.sh and copy it into
# $PATCHES first; this script consumes the patch, not the module sources.
set -eo pipefail
# The chroot below runs in a PRIVATE mount namespace: nothing it mounts is
# visible to the host, and no unmount can propagate out (the 2026-08-10
# "PTY allocation failed" incident — scripts/lib/chroot-guard.sh). This script
# is also copied to the box, so the guard is loaded from the repo if it is
# beside us and from /usr/local/bin/chroot-guard otherwise.
CHROOT_GUARD_LIB="$(dirname "${BASH_SOURCE[0]}")/../../../lib/chroot-guard.sh"
# shellcheck disable=SC1090,SC1091
if [ -f "$CHROOT_GUARD_LIB" ]; then . "$CHROOT_GUARD_LIB"; else . /usr/local/bin/chroot-guard; fi
chroot_guard_reexec_private "$@"
C=${MAMECTL_CHROOT:-/data/vms/soltest/trixie-chroot}
T=$C/build/mame
PATCHES=${MAMECTL_PATCHES:-/root/mame-stack-v3}
OUT=${1:-/data/vms/soltest/movea-v2-build/sgi-dev}
LOG=${MAMECTL_LOG:-/data/vms/soltest/movea-v2-build/mamectl-build.log}

cd "$T"
git status --porcelain | grep -q . && {
  echo "TREE NOT PRISTINE"
  git status --short | head
  exit 1
}
restore() {
  cd "$T" && git checkout -- . 2>/dev/null
  git clean -fdq src/osd/modules/ctlsock 2>/dev/null
}
trap restore EXIT

# shellcheck source=/dev/null  # lives on the box, beside the patches
. "$PATCHES/irix-mame-stack.sh"
irix_mame_apply "$T" "$PATCHES" || {
  echo "STACK APPLY FAILED"
  exit 1
}
[ -f "$T/src/osd/modules/ctlsock/ctlsock.cpp" ] || {
  echo "ctlsock source missing after stack"
  exit 1
}

chroot "$C" /bin/bash -c \
  'cd /build/mame && make SUBTARGET=sgi SOURCES=src/mame/sgi/indy_indigo2.cpp \
   REGENIE=1 USE_QTDEBUG=0 TOOLS=0 -j16' >"$LOG" 2>&1 || {
  echo "BUILD FAILED"
  grep -E "error:|Error " "$LOG" | head -20
  exit 1
}
grep -qE "error:" "$LOG" && {
  echo "BUILD ERRORS"
  grep -E "error:" "$LOG" | head -20
  exit 1
}

install -m 755 "$T/sgi" "$OUT"
md5sum "$OUT"
