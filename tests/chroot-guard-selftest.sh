#!/bin/bash
# chroot-guard-selftest.sh — proof that scripts/lib/chroot-guard.sh actually
# stops the 2026-08-10 "PTY allocation failed" incident from recurring.
#
# THE INCIDENT, in one paragraph: the host's /dev is `shared:2` propagation. A
# chroot rig did `mount --rbind /dev $CHROOT/dev`, which joins that peer group,
# so the copy's /dev/pts became a PEER of the real one. Unmount propagates to
# the peers of the unmounted mount's PARENT — so tearing the chroot down with
# `umount $CHROOT/dev/pts` unmounted the HOST's /dev/pts. Sessions already
# holding a pty kept working and `ssh lab '<cmd>'` was unaffected, so nothing
# looked wrong until somebody opened a new interactive session and got
# "PTY allocation failed".
#
# This test reproduces that with a stand-in "host" /dev (a shared tmpfs with a
# devpts child) so nothing real is at risk, and shows:
#   OLD pattern (rbind, no --make-rprivate)  -> the stand-in /dev/pts is
#                                               unmounted by propagation
#   NEW pattern (chroot_guard_mount_api /
#                chroot_guard_umount_all)    -> it survives
# plus the guard's fail-closed refusals.
#
# The whole run happens inside a private mount namespace it enters itself, so
# even the deliberately BROKEN old pattern cannot touch the real host.
#
#   Run ON THE BOX, as root:  bash tests/chroot-guard-selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${CHROOT_GUARD_LIB:-$HERE/../scripts/lib/chroot-guard.sh}"

[ "$(id -u)" -eq 0 ] || {
  echo "this selftest mounts things; run it as root on the lab box" >&2
  exit 2
}
command -v unshare >/dev/null || {
  echo "unshare(1) required" >&2
  exit 2
}

# Enter our own mount namespace FIRST, before anything is mounted. --propagation
# unchanged is deliberate: we need to be able to build a *shared* stand-in mount
# inside, which is what makes the old-pattern reproduction faithful. Nothing we
# mount is under a host path, and the namespace dies with this script.
if [ "${CHG_SELFTEST_NS:-0}" != 1 ]; then
  export CHG_SELFTEST_NS=1
  exec unshare --mount --propagation unchanged -- "${BASH:-/bin/bash}" "$0" "$@"
fi
# Make sure nothing we do can travel back to the host's namespace.
mount --make-rslave / 2>/dev/null || mount --make-rprivate / 2>/dev/null || true

# shellcheck disable=SC1090
. "$LIB"

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf 'PASS  %s\n' "$*"
}
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$*"
}
check() { # check <description> <expect-ok|expect-fail> <cmd...>
  local desc="$1" want="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    if [ "$want" = ok ]; then ok "$desc"; else bad "$desc (unexpectedly succeeded)"; fi
  else
    if [ "$want" = fail ]; then ok "$desc"; else bad "$desc (unexpectedly failed)"; fi
  fi
}

W="$(mktemp -d /tmp/chroot-guard-selftest-XXXXXX)"
cleanup() {
  chroot_guard_umount_all "$W/root-new" >/dev/null 2>&1
  chroot_guard_umount_all "$W/root-old" >/dev/null 2>&1
  umount -R "$W/hostdev" >/dev/null 2>&1
  rm -rf "$W"
}
trap cleanup EXIT

mkdir -p "$W/hostdev" "$W/root-old/dev" "$W/root-new/dev"

# ---- the stand-in for the host's shared /dev -------------------------------
make_hostdev() {
  mount -t tmpfs tmpfs "$W/hostdev" || return 1
  mount --make-shared "$W/hostdev" || return 1
  mkdir -p "$W/hostdev/pts"
  mount -t devpts devpts "$W/hostdev/pts" || return 1
}
hostdev_pts_alive() { mountpoint -q "$W/hostdev/pts"; }

# ---- 1. the OLD pattern loses the stand-in /dev/pts ------------------------
make_hostdev || {
  echo "cannot build the stand-in /dev (tmpfs+devpts)" >&2
  exit 2
}
if hostdev_pts_alive; then
  ok "stand-in /dev/pts is mounted before the old-pattern teardown"
else
  bad "stand-in /dev/pts did not mount"
fi
mount --rbind "$W/hostdev" "$W/root-old/dev" # <- the bug: no --make-rprivate
umount "$W/root-old/dev/pts" 2>/dev/null     # <- the teardown that escaped
if hostdev_pts_alive; then
  bad "OLD pattern did NOT propagate — this box does not reproduce the incident"
else
  ok "OLD pattern (rbind + umount, no --make-rprivate) unmounted the stand-in host /dev/pts — incident reproduced"
fi
umount -R "$W/root-old/dev" 2>/dev/null
umount -R "$W/hostdev" 2>/dev/null

# ---- 2. the NEW pattern does not -------------------------------------------
make_hostdev || {
  echo "cannot rebuild the stand-in /dev" >&2
  exit 2
}
mount --rbind "$W/hostdev" "$W/root-new/dev"
mount --make-rprivate "$W/root-new/dev" # <- what chroot_guard_mount_api does
chroot_guard_umount_all "$W/root-new" >/dev/null 2>&1
if hostdev_pts_alive; then
  ok "NEW pattern (--make-rprivate + chroot_guard_umount_all) left the stand-in host /dev/pts mounted"
else
  bad "NEW pattern still unmounted the stand-in host /dev/pts"
fi
if mountpoint -q "$W/root-new/dev"; then
  bad "teardown left $W/root-new/dev mounted"
else
  ok "teardown removed every mount under the chroot root"
fi
umount -R "$W/hostdev" 2>/dev/null

# ---- 3. mount-api on the real /proc,/sys,/dev (inside this namespace) ------
if chroot_guard_mount_api "$W/root-new" >/dev/null 2>&1; then
  ok "chroot_guard_mount_api mounted proc/sys/dev"
  if grep -F " $W/root-new/dev " /proc/self/mountinfo | grep -q 'shared:'; then
    bad "$W/root-new/dev is still SHARED after mount-api"
  else
    ok "the chroot's /dev is private (not a peer of the host's)"
  fi
  check "chroot_guard_umount_all tore it down" ok chroot_guard_umount_all "$W/root-new"
  if mountpoint -q /dev/pts; then
    ok "/dev/pts is still mounted after the teardown"
  else
    bad "/dev/pts LOST after the teardown"
  fi
  check "teardown is idempotent (second run is a no-op)" ok \
    chroot_guard_umount_all "$W/root-new"
else
  bad "chroot_guard_mount_api failed"
fi

# ---- 4. fail-closed refusals ------------------------------------------------
check "refuses a root of /" fail chroot_guard_assert_root /
check "refuses a host root (/dev)" fail chroot_guard_assert_root /dev
check "refuses a relative root" fail chroot_guard_assert_root some/where
check "accepts a sandbox root" ok chroot_guard_assert_root "$W/root-new"
check "refuses /dev/pts as a path under the chroot" fail \
  chroot_guard_assert_under "$W/root-new" /dev/pts
check "refuses a ../ escape" fail \
  chroot_guard_assert_under "$W/root-new" "$W/root-new/../../etc"
check "accepts a real path under the chroot" ok \
  chroot_guard_assert_under "$W/root-new" "$W/root-new/dev/pts"
check "refuses umount-all on /" fail chroot_guard_umount_all /
check "refuses mount-api on /" fail chroot_guard_mount_api /

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
