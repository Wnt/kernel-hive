#!/bin/bash
# tile-lifecycle-check.sh <tile> — assert that `systemctl stop streamhost@<tile>`
# leaves NOTHING behind. Run ON the box as root.
#
# Why this exists. The IRIX station's liveness watchdog was found alive after
# `systemctl stop streamhost@irix`, still holding a relaunch budget — i.e. the
# stopped exhibit could have restarted itself. Two independent defects produced
# it, and each one alone is enough:
#
#   1. ensure-tile-{qemu,x11}.sh launch the guest with `systemd-run --scope`,
#      which puts the launcher and every descendant (emulator, Xvfb, boot
#      watchdog, liveness watchdog) in a cgroup with NO relationship to the
#      service. No KillMode= on the unit can reach it. Fixed by making the scope
#      BindsTo= the service.
#   2. The unit ran KillMode=process, so anything the launcher backgrounded into
#      the service's OWN cgroup outlived the stop as well, and teardown rested
#      entirely on ExecStop finding every pidfile. Fixed by KillMode=mixed.
#
# That is a measurement-integrity bug as much as an ops bug: most of this
# project's performance work is done "with the tiles stopped", and until this was
# fixed that sentence was not reliably true.
#
# NEVER point this at a production station you are not allowed to cycle. The
# intended target is a throwaway instance of the SAME template with its own
# tile.env, SH_PORT and station dir — that exercises the real unit, the real
# ExecStartPre/ExecStop and the real launcher without touching an exhibit.
set -u

T="${1:-}"
[ -n "$T" ] || {
  echo "usage: $0 <tile>" >&2
  exit 2
}
D="/data/vms/streamhost/tiles/$T"
SETTLE="${LIFECYCLE_SETTLE:-20}"
FAIL=0

# Everything whose argv mentions this station's directory. Deliberately NOT a
# `pkill -f`-shaped name match: over ssh that pattern also matches the ssh
# command line itself, which has killed sessions on this box before.
survivors() {
  # shellcheck disable=SC2009 # pgrep -f is exactly what must NOT be used here:
  # over ssh its pattern also matches the ssh command line carrying it.
  ps -eo pid,args --no-headers | grep -F "/tiles/$T/" | grep -v "tile-lifecycle-check"
}
scopes() { systemctl list-units "qcap-$T-*" --all --no-legend | awk '{print $1, $4}'; }

assert_clean() { # $1 = label
  local procs scope
  sleep 3
  procs="$(survivors)"
  scope="$(scopes)"
  if [ -n "$procs" ] || [ -n "$scope" ]; then
    echo "  FAIL [$1] something survived the stop:"
    [ -n "$procs" ] && printf '    proc  %s\n' "$procs"
    [ -n "$scope" ] && printf '    scope %s\n' "$scope"
    FAIL=1
  else
    echo "  PASS [$1] no processes, no scope"
  fi
}

report_up() { # $1 = label
  echo "  up [$1]: service=$(systemctl is-active "streamhost@$T.service") scope=$(scopes)"
  survivors | cut -c1-120
}

for round in 1 2 3; do
  echo "== round $round: start -> stop =="
  systemctl start "streamhost@$T.service"
  sleep "$SETTLE"
  report_up "round $round"
  systemctl stop "streamhost@$T.service"
  assert_clean "round $round stop"
done

# The watchdog spends most of its life inside a probe: two 3-second sleeps with
# an emulated pointer nudge between them. A stop that lands there is the case a
# pidfile pass is most likely to fumble, so it gets its own round.
echo "== round 4: stop issued while the liveness watchdog is MID-PROBE =="
systemctl start "streamhost@$T.service"
sleep $((SETTLE + 5))
for _ in $(seq 1 30); do
  grep -q "probe(" "$D/livewatch.log" 2>/dev/null && break
  sleep 2
done
tail -3 "$D/livewatch.log" 2>/dev/null | sed 's/^/    /'
# shellcheck disable=SC2009 # see survivors(): pgrep would match this script's own argv.
echo "  probe sleeps in flight at stop time: $(ps -eo args --no-headers | grep -c '[s]leep 3')"
systemctl stop "streamhost@$T.service"
assert_clean "round 4 mid-probe stop"

echo "== round 5: systemctl restart leaves exactly one of everything =="
systemctl start "streamhost@$T.service"
sleep "$SETTLE"
before="$(scopes)"
systemctl restart "streamhost@$T.service"
sleep "$SETTLE"
after="$(scopes)"
echo "  scope before restart: $before"
echo "  scope after  restart: $after"
nb="$(survivors | grep -c -- '--bootwatch')"
nl="$(survivors | grep -c -- '--livewatch')"
echo "  bootwatch=$nb livewatch=$nl (each must be exactly 1)"
[ "$nb" = 1 ] && [ "$nl" = 1 ] || {
  echo "  FAIL duplicate or missing watchdog after restart"
  FAIL=1
}
[ "$before" != "$after" ] || {
  echo "  FAIL the restart reused the old scope — it was never torn down"
  FAIL=1
}
systemctl stop "streamhost@$T.service"
assert_clean "round 5 restart then stop"

echo
if [ "$FAIL" = 0 ]; then
  echo "ALL LIFECYCLE ASSERTIONS PASSED — \"$T is stopped\" is a fact"
else
  echo "LIFECYCLE FAILURES PRESENT for $T"
fi
exit "$FAIL"
