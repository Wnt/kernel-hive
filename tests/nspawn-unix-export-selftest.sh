#!/bin/bash
# nspawn-unix-export-selftest.sh — proves scripts/lib/nspawn-unix-export.sh:
#   1 a stale mount that clears by itself within the wait -> success, not forced
#   2 one that never clears -> force-cleared (umount called, dir removed)
#   3 one held by a live machine (machinectl)  -> refused, left alone
#   4 one held by a live nspawn process (/proc exe + --machine=) -> refused
#   5 an absent path is an immediate success; a sibling machine's dir is never touched
# Runs unprivileged: the export dir, machinectl, umount and the nspawn binary
# are all test seams pointing into a temp dir.
set -u
LIB="$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/nspawn-unix-export.sh"
T="$(mktemp -d)"
FAILS=0
FAKE_PID=""
cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
ok() { printf 'ok   %s\n' "$1"; }
bad() {
  printf 'FAIL %s\n' "$1"
  FAILS=$((FAILS + 1))
}

export NSPAWN_EXPORT_DIR="$T/ux"
mkdir -p "$NSPAWN_EXPORT_DIR"
printf '#!/bin/sh\nexit 1\n' >"$T/machinectl-none"
printf '#!/bin/sh\nexit 0\n' >"$T/machinectl-live"
# shellcheck disable=SC2016 # the stub script body must keep a literal $1
printf '#!/bin/sh\necho "$1" >>%s/umount.log\n' "$T" >"$T/umount"
chmod +x "$T"/machinectl-* "$T/umount"
export NSPAWN_MACHINECTL="$T/machinectl-none" NSPAWN_UMOUNT="$T/umount"
export NSPAWN_BIN="$T/fake-nspawn"
cp "$(command -v perl)" "$NSPAWN_BIN"
# shellcheck source=/dev/null
. "$LIB"

# 5 absent -> immediate success
if nspawn_export_clear kh-a 1; then ok "absent path succeeds"; else bad "absent path"; fi

# 1 clears within the wait
mkdir "$NSPAWN_EXPORT_DIR/kh-a"
(
  sleep 1
  rmdir "$NSPAWN_EXPORT_DIR/kh-a"
) &
: >"$T/umount.log"
if nspawn_export_clear kh-a 5 2>"$T/err" && [ ! -s "$T/umount.log" ] && ! grep -q clearing "$T/err"; then
  ok "stale mount that clears within the wait (no force)"
else bad "clears within wait"; fi
wait

# 2 must be force-cleared; sibling untouched
mkdir "$NSPAWN_EXPORT_DIR/kh-a" "$NSPAWN_EXPORT_DIR/kh-b"
if nspawn_export_clear kh-a 1 2>"$T/err" && [ ! -e "$NSPAWN_EXPORT_DIR/kh-a" ] &&
  grep -q "kh-a" "$T/umount.log" && [ -d "$NSPAWN_EXPORT_DIR/kh-b" ] && ! grep -q kh-b "$T/umount.log"; then
  ok "stale mount is force-cleared; sibling machine untouched"
else bad "force clear"; fi

# 3 live machine (machinectl)
mkdir -p "$NSPAWN_EXPORT_DIR/kh-a"
: >"$T/umount.log"
if NSPAWN_MACHINECTL="$T/machinectl-live" nspawn_export_clear kh-a 1 2>"$T/err"; then
  bad "live machine was cleared"
elif [ -d "$NSPAWN_EXPORT_DIR/kh-a" ] && [ ! -s "$T/umount.log" ] && grep -q LIVE "$T/err"; then
  ok "refuses while machinectl knows the machine"
else bad "live machine refusal"; fi

# 4 live nspawn process, unregistered (--register=no)
"$NSPAWN_BIN" -e 'sleep 60' -- --machine=kh-a &
FAKE_PID=$!
if nspawn_export_clear kh-a 1 2>"$T/err"; then
  bad "live process was cleared"
elif [ -d "$NSPAWN_EXPORT_DIR/kh-a" ] && [ ! -s "$T/umount.log" ] && grep -q "$FAKE_PID" "$T/err"; then
  ok "refuses while a systemd-nspawn process holds the name"
else bad "live process refusal"; fi
# ...but a process of ANOTHER machine name does not block clearing kh-c
mkdir "$NSPAWN_EXPORT_DIR/kh-c"
if nspawn_export_clear kh-c 1 2>/dev/null; then ok "another machine's live process does not block"; else bad "cross-machine block"; fi

# 6 orphan sweep: supervisor dies, its stub init (a child) survives -> swept.
# The "supervisor" and "init" are both copies of the fake nspawn binary.
# shellcheck disable=SC2016 # perl source, not shell
FK="$NSPAWN_BIN" "$NSPAWN_BIN" -e 'if (fork == 0) { exec $ENV{FK}, "-e", "sleep 60" } sleep 60' &
SUP=$!
for _ in $(seq 1 40); do
  [ -n "$(nspawn_init_pids "$SUP")" ] && break
  sleep 0.1
done
INIT="$(nspawn_init_pids "$SUP")"
kill -KILL "$SUP" 2>/dev/null
wait "$SUP" 2>/dev/null
if [ -n "$INIT" ] && kill -0 "$INIT" 2>/dev/null && nspawn_sweep_init "$INIT" && ! readlink "/proc/$INIT/exe" >/dev/null 2>&1; then
  ok "orphaned stub init is swept after its supervisor died"
else bad "orphan sweep"; fi
# ...and a pid whose exe is NOT nspawn (a recycled pid) is never signalled
sleep 30 &
BYST=$!
nspawn_sweep_init "$BYST"
if kill -0 "$BYST" 2>/dev/null; then ok "non-nspawn pid is left alone"; else bad "sweep killed a bystander"; fi
kill "$BYST" 2>/dev/null

# 7 stop_container: kills the init, then the supervisor (this fake supervisor
# does not exit by itself, so the bounded wait ends in SIGKILL of it)
# shellcheck disable=SC2016 # perl source, not shell
FK="$NSPAWN_BIN" "$NSPAWN_BIN" -e 'if (fork == 0) { exec $ENV{FK}, "-e", "sleep 60" } sleep 60' &
SUP=$!
for _ in $(seq 1 40); do
  [ -n "$(nspawn_init_pids "$SUP")" ] && break
  sleep 0.1
done
INIT="$(nspawn_init_pids "$SUP")"
if [ -n "$INIT" ] && nspawn_stop_container "$SUP" 1 && ! readlink "/proc/$INIT/exe" >/dev/null 2>&1 &&
  ! readlink "/proc/$SUP/exe" >/dev/null 2>&1; then
  ok "stop_container removes the init and the supervisor"
else bad "stop_container"; fi
wait "$SUP" 2>/dev/null

if [ "$FAILS" -eq 0 ]; then echo PASS; else
  echo "FAILED: $FAILS"
  exit 1
fi
