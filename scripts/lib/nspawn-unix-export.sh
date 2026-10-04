#!/bin/bash
# nspawn-unix-export.sh — the ONE answer to "Mount point
# '/run/systemd/nspawn/unix-export/<machine>' exists already, refusing".
#
# SOURCE it from a station launcher (installed at
# /usr/local/lib/nspawn-unix-export.sh by the box-sync pair) and call
# nspawn_export_clear <machine> right before `systemd-nspawn`, AFTER the launcher
# has reaped its previous container:
#
#   # shellcheck source=/dev/null
#   . /usr/local/lib/nspawn-unix-export.sh || { echo "no nspawn-unix-export.sh" >&2; exit 1; }
#   nspawn_export_clear "$MACHINE" || exit 1
#
# WHY. systemd-nspawn mounts a per-machine tmpfs at unix-export/<machine> and
# unmounts it during teardown, but that teardown is ASYNCHRONOUS: it lands a
# beat AFTER the container's pids are gone. A restart (and every reset on a
# relaunch-resets station) therefore races it, and loses intermittently — seen
# on vision (2026-09-13), perq, mvs38 (2026-09-20), nokia9300 (2026-09-24) and
# again on perq in the 2026-10-04 fleet rollout, where one failed restart made
# the rollout tool roll a wave back. vision's x11-runtime.sh had the proven fix
# (wait, then clear by force); this is that fix, shared.
#
# CONTRACT  nspawn_export_clear <machine> [wait_seconds=10]
#   returns 0  the path is gone (it went by itself within the wait, or it was
#              stale and was force-cleared: umount + rmdir)
#   returns 1  it will not go, or a LIVE container of that name holds it; says
#              why on stderr. The launcher must then abort — never start nspawn
#              on top of it, never fall back.
# It touches ONLY unix-export/<machine> for the machine it is given, and only
# when no live container of that name exists:
#   - machinectl show <machine> answers (registered machines), or
#   - a process whose /proc/<pid>/exe is systemd-nspawn carries the exact
#     argument --machine=<machine> (our launchers pass --register=no, so
#     machinectl alone cannot see them). Resolved via /proc exe, never a
#     cmdline grep of ps (AGENTS.md rule 5).
# Machine names are load-bearing (something on the box reaps unrecognised kh-*
# machines): this helper never renames or invents one.
#
# Test seams (tests/nspawn-unix-export-selftest.sh): NSPAWN_EXPORT_DIR,
# NSPAWN_MACHINECTL, NSPAWN_BIN, NSPAWN_UMOUNT.

# nspawn_live_pids <machine> — pids of live systemd-nspawn supervisors for it.
nspawn_live_pids() {
  local machine="$1" want p exe
  want="$(readlink -f "${NSPAWN_BIN:-$(command -v systemd-nspawn || echo /usr/bin/systemd-nspawn)}")"
  for p in /proc/[0-9]*; do
    exe="$(readlink "$p/exe" 2>/dev/null)" || continue
    [ "${exe% (deleted)}" = "$want" ] || continue
    if tr '\0' '\n' <"$p/cmdline" 2>/dev/null | grep -Fxq -- "--machine=$machine"; then
      printf '%s\n' "${p#/proc/}"
    fi
  done
}

nspawn_export_clear() {
  local machine="${1:?nspawn_export_clear: machine name required}" wait_s="${2:-10}"
  local dir="${NSPAWN_EXPORT_DIR:-/run/systemd/nspawn/unix-export}"
  local ux="$dir/$machine" mctl="${NSPAWN_MACHINECTL:-machinectl}" i live
  case "$machine" in */* | '' | . | ..)
    echo "nspawn_export_clear: bad machine name '$machine'" >&2
    return 1
    ;;
  esac

  # 1. nspawn's own teardown is in flight: give it the wait (4 polls/second).
  for ((i = 0; i < wait_s * 4; i++)); do
    [ -e "$ux" ] || return 0
    sleep 0.25
  done
  [ -e "$ux" ] || return 0

  # 2. still there. Is it held by a live container of this name?
  live="$(nspawn_live_pids "$machine" | tr '\n' ' ')"
  if "$mctl" show "$machine" >/dev/null 2>&1 || [ -n "$live" ]; then
    echo "nspawn_export_clear: $ux is held by a LIVE container '$machine'" \
      "(pids: ${live:-registered machine}) — refusing to clear it" >&2
    return 1
  fi

  # 3. stale: force-clear exactly that path.
  echo "nspawn_export_clear: $ux outlived the ${wait_s}s teardown wait with no live '$machine' — clearing" >&2
  "${NSPAWN_UMOUNT:-umount}" "$ux" 2>/dev/null || true
  rmdir "$ux" 2>/dev/null || true
  if [ -e "$ux" ]; then
    echo "nspawn_export_clear: $ux will not go away — refusing to start '$machine' on top of it" >&2
    return 1
  fi
  return 0
}
