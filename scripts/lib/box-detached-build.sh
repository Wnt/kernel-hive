#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# box-detached-build.sh — run a LONG build on the lab box, detached from the ssh
# session that started it, stream its log back, and be able to stop it again.
#
# Sourced, not executed. Extracted from scripts/dev/migrate-tile.sh, where all
# three of the traps below were paid for in production incidents.
#
#   * DETACHED, because a 40-minute build must not die with the ssh session.
#     `setsid` also makes the builder a process-group LEADER, so the $$ it
#     records is a PGID — and a PGID is what box_build_stop needs, since the
#     build starts a QEMU that a bare kill of the shell would leave behind.
#   * METADATA FIRST when polling. An earlier shape streamed the new log lines
#     first and split them from the trailing metadata on a '---' sentinel; when
#     a poll found NO new lines nothing matched, the line COUNT was parsed as
#     the exit code, and a perfectly healthy build was declared "builder exited
#     3" and rolled back. Any tile with a quiet stretch — plus4 spends ~46 s in
#     wait_for_ssh saying nothing — hit that every single time. Fixed-position
#     leading fields cannot be confused by log content, quiet or noisy.
#   * STOPPABLE, because nothing reaps a detached builder when the caller gives
#     up on it. plus4 again: the poll aborted, the caller restored the previous
#     disk image, and the builder carried on for another minute against the file
#     it had just been handed back, re-baking a golden into the PRODUCTION
#     overlay. Whoever abandons the build owes it a kill.
#
# The caller supplies how to reach the box, as an array:
#     BOX_BUILD_SSH=(ssh -o ConnectTimeout=15 lab)
#
#     box_build_start <stage> <relpath> <log> [VAR=VAL …]
#         cd <stage>; run `bash <relpath> --force` with the given environment,
#         detached, logging to <log>. Writes <log>.pid (the PGID) and, on exit,
#         <log>.rc. Removes all three first, so a rerun cannot read stale state.
#     box_build_wait <log> <timeout-s> [poll-s]
#         Stream new log lines to stdout, prefixed. Sets BOX_BUILD_RC to the
#         builder's exit code, or leaves it empty on timeout. Returns non-zero
#         only if the box became unreadable.
#     box_build_stop <log>
#         Kill the builder's whole process group, but ONLY while it is genuinely
#         still running: an existing <log>.rc means it finished on its own and
#         the recorded pgid may since have been reused by an unrelated process.
# =============================================================================

BOX_BUILD_RC=""

_bbd_ssh() { "${BOX_BUILD_SSH[@]}" "$@"; }

box_build_start() {
  local stage="$1" rel="$2" log="$3"
  shift 3
  _bbd_ssh bash -s -- "$stage" "$rel" "$log" "$*" <<'EOS'
set -eu
stage=$1 rel=$2 log=$3 envs=$4
rm -f "$log" "$log.rc" "$log.pid"
cd "$stage"
setsid bash -c "echo \$\$ >'$log.pid'; env $envs bash '$rel' --force >'$log' 2>&1; echo \$? >'$log.rc'" \
  </dev/null >/dev/null 2>&1 &
for _ in $(seq 1 20); do [ -s "$log.pid" ] && break; sleep 0.5; done
echo "builder pgid $(cat "$log.pid" 2>/dev/null || echo '?')"
EOS
}

box_build_wait() {
  local log="$1" timeout="$2" poll="${3:-20}"
  local elapsed=0 seen=0 chunk lines new
  BOX_BUILD_RC=""
  while [ "$elapsed" -lt "$timeout" ]; do
    sleep "$poll"
    elapsed=$((elapsed + poll))
    chunk="$(
      _bbd_ssh bash -s -- "$log" "$seen" <<'EOS'
set -u
log=$1 seen=$2
printf '%s\n' "$(wc -l <"$log" 2>/dev/null || echo 0)" "$(cat "$log.rc" 2>/dev/null || true)"
tail -n +$((seen + 1)) "$log" 2>/dev/null || true
EOS
    )" || return 1
    lines="$(printf '%s\n' "$chunk" | sed -n 1p)"
    BOX_BUILD_RC="$(printf '%s\n' "$chunk" | sed -n 2p)"
    new="$(printf '%s\n' "$chunk" | sed -n '3,$p')"
    case "$lines" in
      '' | *[!0-9]*)
        echo "box-detached-build: unparseable log line count '$lines'" >&2
        return 1
        ;;
      *) seen="$lines" ;;
    esac
    [ -n "$new" ] && printf '%s\n' "$new" | sed 's/^/    | /'
    [ -n "$BOX_BUILD_RC" ] && return 0
    [ $((elapsed % 300)) -eq 0 ] && echo "    (still building, ${elapsed}s)"
  done
  return 0
}

box_build_stop() {
  _bbd_ssh bash -s -- "$1" <<'EOS'
set -u
log=$1
[ -f "$log.rc" ] && { echo "builder already finished (rc=$(cat "$log.rc")); nothing to stop"; exit 0; }
pgid=$(cat "$log.pid" 2>/dev/null || true)
case "$pgid" in
  '' | *[!0-9]*) echo "no builder pgid recorded; nothing to stop"; exit 0 ;;
esac
kill -TERM "-$pgid" 2>/dev/null || true
for _ in $(seq 1 20); do kill -0 "-$pgid" 2>/dev/null || break; sleep 1; done
kill -KILL "-$pgid" 2>/dev/null || true
sleep 1
if kill -0 "-$pgid" 2>/dev/null; then
  # FAIL CLOSED. A surviving builder still addresses the guest as
  # 127.0.0.1:<hostfwd>, so if the caller now restores and restarts the tile the
  # builder provisions the PRODUCTION guest — which is the plus4/decos incident
  # this file exists to prevent. A warning here would let the caller carry on
  # and reproduce it, so this is an error the caller must handle.
  echo "ERROR: builder group $pgid SURVIVED both signals — do NOT touch the overlay" >&2
  exit 1
fi
echo "builder group $pgid stopped"
exit 0
EOS
}
