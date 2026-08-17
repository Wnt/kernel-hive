#!/usr/bin/env bash
# mount-sentinel.sh — restore stripped host API mounts on labhost, loudly.
#
# WHY THIS EXISTS. The labhost mount tree is `shared:2`; a chroot teardown that
# bypasses chroot-guard propagates its unmounts back to the HOST. It has
# happened twice:
#   2026-08-10  /dev/pts stripped -> new interactive ssh logins died.
#   2026-08-17  securityfs + 9 more /sys+/dev submounts stripped -> dbus-daemon
#               could not resolve AppArmor peer labels -> the Proxmox pre-start
#               hook's `timedatectl` D-Bus call was denied -> `pct start`
#               failed for every container. Latent for hours until the first
#               guest restart, and the visible error (an AppArmor dbus denial)
#               was three causal steps from the root cause.
# Prevention lives in chroot-guard and the repo's mount-guard hook; this is the
# safety net behind them: heal within minutes, and leave a timestamped journal
# line that implicates whatever ran at the moment of the strip.
#
# Deployed as /usr/local/bin/mount-sentinel, driven by mount-sentinel.timer
# (scripts/host/mount-sentinel.{service,timer} -> /etc/systemd/system, see
# scripts/lib/box-sync-pairs.sh). Run it by hand any time; it is idempotent
# and only ever ADDS mounts — it never unmounts anything.
#
# Exit: 0 when every canonical mount is present (restored or already there),
# non-zero when one could not be restored — the service unit then shows failed.
set -uo pipefail

TAG=mount-sentinel
RESTORED=0
FAILED=0

if [ "$(id -u)" -ne 0 ]; then
  echo "$TAG: needs root" >&2
  exit 2
fi

# ensure <target> <fstype> <source> <options> — mount if nothing is mounted at
# <target>. An existing mount of any fstype counts as present (binfmt_misc is
# normally systemd's autofs trigger, /dev/shm may legitimately be resized).
ensure() {
  local tgt="$1" fstype="$2" src="$3" opts="$4"
  findmnt -n "$tgt" >/dev/null 2>&1 && return 0
  if [ ! -d "$tgt" ]; then
    logger -t "$TAG" -p daemon.err "FAILED $tgt: mountpoint directory missing"
    FAILED=$((FAILED + 1))
    return 1
  fi
  if mount -t "$fstype" -o "$opts" "$src" "$tgt"; then
    logger -t "$TAG" -p daemon.err \
      "RESTORED $tgt ($fstype) — a host API mount was missing. Something unmounted host mounts (shared:2 propagation; see chroot-guard header, incidents 2026-08-10 and 2026-08-17). Check what ran on labhost just before this timestamp."
    RESTORED=$((RESTORED + 1))
  else
    logger -t "$TAG" -p daemon.err "FAILED to mount $tgt ($fstype)"
    FAILED=$((FAILED + 1))
    return 1
  fi
}

# The canonical host API mount set, with stock Debian/systemd options. devpts
# options are the exact recovery line from the 2026-08-10 incident.
ensure /sys/kernel/security securityfs securityfs rw,nosuid,nodev,noexec
ensure /dev/pts devpts devpts rw,nosuid,noexec,gid=5,mode=620,ptmxmode=000
ensure /dev/shm tmpfs tmpfs rw,nosuid,nodev
ensure /dev/mqueue mqueue mqueue rw,nosuid,nodev,noexec
ensure /dev/hugepages hugetlbfs hugetlbfs rw,pagesize=2M
ensure /sys/kernel/debug debugfs debugfs rw,nosuid,nodev,noexec
ensure /sys/kernel/tracing tracefs tracefs rw,nosuid,nodev,noexec
ensure /sys/kernel/config configfs configfs rw,nosuid,nodev,noexec
ensure /sys/fs/bpf bpf bpf rw,nosuid,nodev,noexec,mode=700
ensure /sys/fs/pstore pstore pstore rw,nosuid,nodev,noexec
ensure /sys/fs/fuse/connections fusectl fusectl rw,nosuid,nodev,noexec
ensure /proc/sys/fs/binfmt_misc binfmt_misc binfmt_misc rw,nosuid,nodev,noexec

if [ "$RESTORED" -gt 0 ] || [ "$FAILED" -gt 0 ]; then
  echo "$TAG: restored=$RESTORED failed=$FAILED (journalctl -t $TAG for detail)"
fi
[ "$FAILED" -eq 0 ]
