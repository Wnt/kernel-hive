#! /sbin/sh
# irixagent.sh — supervised entry point for the IRIX serial command agent.
#
# Started from /etc/inittab:
#     ia:23:respawn:/usr/local/bin/irixagent.sh </dev/null >/dev/null 2>&1
# init supervises it, so the agent survives a crash and comes back on its own;
# `/etc/telinit q` applies an inittab change without the tile's 4.5-minute cold
# boot. Guest end of the line is /dev/ttyd2 (physical serial port 2), which
# /etc/inittab leaves free — its getty entry `t2` ships `off`. Port 1 is left
# alone: `t1` is a respawning console getty and the PROM writes there.
#
# The sleeps are load-bearing, not decoration: SysV init disables a respawn
# entry that restarts more than ~10 times in ~2 minutes ("Command is respawning
# too rapidly"), and on a tile whose cold boot is 4.5 minutes that is an
# expensive way to find out about a typo.
#
# NO COMMAND SUBSTITUTION ANYWHERE. IRIX 6.5's /sbin/sh is the SVR4 Bourne
# shell: `$(...)` is a syntax error and backticks do not survive shfmt, which
# rewrites them into `$(...)`. The agent timestamps its own log lines instead.
PATH=/usr/local/bin:/usr/sbin:/usr/bsd:/sbin:/usr/bin:/etc:/usr/etc
export PATH
IRIXAGENT_DEV=${IRIXAGENT_DEV:-/dev/ttyd2}
export IRIXAGENT_DEV
LOG=/var/tmp/irixagent.log

if [ ! -c "$IRIXAGENT_DEV" ]; then
  echo "irixagent: $IRIXAGENT_DEV is not a character device" >>$LOG
  date >>$LOG
  sleep 30
  exit 1
fi
if [ ! -f /usr/local/bin/irixagent.pl ]; then
  echo "irixagent: /usr/local/bin/irixagent.pl missing" >>$LOG
  date >>$LOG
  sleep 30
  exit 1
fi

/usr/bin/perl /usr/local/bin/irixagent.pl >>$LOG 2>&1
rc=$?
echo "irixagent: exited rc=$rc" >>$LOG
date >>$LOG
sleep 5
exit $rc
