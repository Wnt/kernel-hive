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
# SECOND JOB — orphans (found 2026-10-04 in the perq restart proof). Killing or
# TERMing the nspawn SUPERVISOR does not end the container: its direct child, the
# stub init (PID 1 of the container's PID namespace), survives with the
# `script` pty wrapper (held open on a FIFO, never sees EOF), Xvfb and any
# emulator under it — one leaked ~25-40% CPU instance per restart, invisible to
# a pidfile that now names the dead supervisor. So, around the launcher's own
# reap:
#   PREV_INIT="$(nspawn_init_pids "$(cat "$NSPAWN_PIDFILE" 2>/dev/null)")"   # BEFORE
#   nspawn_stop_container "$(cat "$NSPAWN_PIDFILE" 2>/dev/null)" || true     # BEFORE
#   reap_previous ...
#   nspawn_sweep_init $PREV_INIT || exit 1                                   # AFTER
# nspawn_sweep_init SIGKILLs a recorded stub init (only if its /proc exe is still
# systemd-nspawn, so a recycled pid is never hit); the kernel then kills the
# whole PID namespace. Returns 1 if one will not die.
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

# nspawn_init_pids <supervisor-pid> — the container init(s): its direct children.
nspawn_init_pids() {
  local sup="$1" want exe
  case "$sup" in '' | *[!0-9]*) return 0 ;; esac
  want="$(readlink -f "${NSPAWN_BIN:-$(command -v systemd-nspawn || echo /usr/bin/systemd-nspawn)}")"
  exe="$(readlink "/proc/$sup/exe" 2>/dev/null)" || return 0
  [ "${exe% (deleted)}" = "$want" ] || return 0
  ps -o pid= --ppid "$sup" 2>/dev/null | tr -d ' ' || true
}

# nspawn_stop_container <supervisor-pid> [wait_seconds=10] — stop a previous
# container the way nspawn can clean up after: SIGKILL its init (the kernel then
# kills the whole PID namespace — script, Xvfb, emulator), and nspawn, seeing the
# container end, exits on its OWN and unmounts unix-export. MEASURED 2026-10-04:
# TERMing the supervisor instead leaves the container (script blocks on its FIFO)
# running 10 s until the launcher's SIGKILL fallback — which skips nspawn's
# cleanup, leaves the unix-export mount behind (every relaunch then paid the 10 s
# wait AND the force-clear) and orphans init/script/Xvfb. Only ever call it with
# THIS station's own recorded supervisor pid; it verifies the exe is systemd-nspawn.
# Returns 0 once the supervisor is gone, 1 if it will not go.
nspawn_stop_container() {
  local sup="$1" wait_s="${2:-10}" want exe p i
  case "$sup" in '' | *[!0-9]*) return 0 ;; esac
  want="$(readlink -f "${NSPAWN_BIN:-$(command -v systemd-nspawn || echo /usr/bin/systemd-nspawn)}")"
  exe="$(readlink "/proc/$sup/exe" 2>/dev/null)" || return 0
  [ "${exe% (deleted)}" = "$want" ] || return 0
  for p in $(nspawn_init_pids "$sup"); do kill -KILL "$p" 2>/dev/null || true; done
  for ((i = 0; i < wait_s * 4; i++)); do
    exe="$(readlink "/proc/$sup/exe" 2>/dev/null)" || return 0
    [ "${exe% (deleted)}" = "$want" ] || return 0
    sleep 0.25
  done
  kill -KILL "$sup" 2>/dev/null || true
  sleep 0.25
  ! readlink "/proc/$sup/exe" >/dev/null 2>&1
}

# nspawn_sweep_init <pid>... — SIGKILL leftover container inits, wait for them.
nspawn_sweep_init() {
  local want p exe i left=""
  want="$(readlink -f "${NSPAWN_BIN:-$(command -v systemd-nspawn || echo /usr/bin/systemd-nspawn)}")"
  for p in "$@"; do
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
    [ "${exe% (deleted)}" = "$want" ] || continue
    kill -KILL "$p" 2>/dev/null || true
  done
  for ((i = 0; i < 20; i++)); do
    left=""
    for p in "$@"; do
      exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
      [ "${exe% (deleted)}" = "$want" ] && left="$left $p"
    done
    [ -z "$left" ] && return 0
    sleep 0.25
  done
  echo "nspawn_sweep_init: container init(s) still alive after SIGKILL:$left" >&2
  return 1
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
