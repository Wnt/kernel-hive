#!/bin/sh
# icbm-watchdog.sh — keep ICBM signed on to the retronet ICQ gateway.
#
# ICBM .71 has no auto-reconnect: when the gateway drops its legacy-UDP session
# (SRV cmd 0x00F0) the client tears the connection down cleanly and then simply
# stays offline for ever. That matters here because this station is
# `loadvm golden` + idle-pause: every visitor restores a snapshot whose in-RAM
# session the server has long since forgotten, and the greeter bot only fires on
# a *sign-on*. Sibling stations get this for free (ICQ 2001b self-heals, Gaim
# has autorecon in-core); on BeOS the reconnect has to be supplied.
#
# Relaunching is the reconnect: `autologin` is set in the per-UIN preferences,
# so a fresh ICBM signs straight back in. The same loop also covers the process
# simply not being there any more.
#
# Installed at /boot/home/config/boot/icbm-watchdog.sh, started by UserBootscript.

APPDIR=/boot/home/apps/ICBM
LOG=/boot/home/icbm.log
SIG=application/x-vnd.ICBM
PERIOD=10

launch() {
  cd "$APPDIR" || return 1
  /boot/beos/bin/sh -c "ICBM.x86 > $LOG 2>&1 < /dev/null &"
}

running() {
  # shellcheck disable=SC2009  # BeOS R5 has no pgrep
  ps | grep ICBM.x86 | grep -v grep >/dev/null 2>&1
}

# Offline when the last teardown is newer than the last successful login.
# Both markers are ICBM's own; the log is truncated on every (re)launch, so the
# line numbers are always relative to the current run.
offline() {
  [ -f "$LOG" ] || return 0
  up=$(grep -n 'LoginSuccessful' "$LOG" | tail -1 | cut -d: -f1)
  down=$(grep -n 'Disconnection finished' "$LOG" | tail -1 | cut -d: -f1)
  [ -z "$up" ] && return 1   # still logging in — not our business yet
  [ -z "$down" ] && return 1 # never torn down — online
  [ "$down" -gt "$up" ]
}

while true; do
  if ! running; then
    launch
  elif offline; then
    quit "$SIG" >/dev/null 2>&1
    sleep 3
    launch
  fi
  sleep $PERIOD
done
