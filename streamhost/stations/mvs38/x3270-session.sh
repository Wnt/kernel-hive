#!/bin/bash
# =============================================================================
# stations/mvs38/x3270-session.sh — the visitor's 3270, INSIDE the container.
#
# This is KH_TERM_CLIENT_CMD for the shared heritage-terminal runtime: it is
# exec'd once the two-condition readiness gate has passed, it owns the window
# the museum publishes, and the container lives exactly as long as it does.
#
# It is a wrapper rather than a bare `exec x3270` because the exhibit's rest
# scene is not "a connected 3270" — it is the ISPF PRIMARY OPTION MENU, and
# MVS will not get there on its own. A 3270 is a block-mode terminal: Hercules
# paints its own device logo on the screen and VTAM says nothing at all until
# something is sent to it, so a station that only started a client would open
# on a static logo and answer nothing a visitor typed until they guessed both
# `TSO` and a TK5 userid. So this script starts x3270, drives the logon through
# x3270's OWN scripting interface, and then hands the session over.
#
# WHY x3270if AND NOT KEYSTROKES: every wait below is on the screen's actual
# text (`Ascii()`), never on a sleep. x3270if reads what the 3270 data stream
# put on the screen, which is the same content the framebuffer then shows, and
# it can distinguish `ENTER USERID` from `ENTER CURRENT PASSWORD` — a
# lit-pixel or "did it change" wait cannot, and this sequence has four
# consecutive screens that differ by one line. The script port is bound on the
# CONTAINER's loopback behind --private-network, so it claims nothing on the
# host and no visitor can reach it.
#
# The password is NOT in this file and not anywhere in the repository: it is
# read from $WORK/tso.pass, which the outer launcher copies from a box-local
# file (MVS38_TSO_PASS_FILE) that is never committed. With no such file the
# script still starts the terminal and simply leaves it at the VTAM screen —
# a degraded exhibit, not a broken one.
# =============================================================================
set -uo pipefail

WORK=/work
DISP="${SH_X11_DISPLAY:?}"
PORT="${MVS38_PORT:-3270}"
SPORT="${MVS38_SCRIPT_PORT:-4001}"
FONT="${MVS38_FONT:-3270-20}"
MODEL="${MVS38_MODEL:-3279-2-E}"
TITLE="${MVS38_WINTITLE:-MVS 3.8j}"
USER_ID="${MVS38_TSO_USER:-HERC01}"
TIMEOUT="${MVS38_LOGON_TIMEOUT_S:-180}"
KEYMAP_RES="$(awk '!/^#/ && NF { printf "%s\\n", $0 }' "$WORK/kh.keymap")"

rm -f "$WORK/logon.ok"

x3270 -display "$DISP" -model "$MODEL" -efont "$FONT" -charset us \
  -keymap kh -xrm "*keymap.kh: $KEYMAP_RES" \
  -scriptport "$SPORT" \
  -xrm "*title: $TITLE" -xrm "*iconName: $TITLE" \
  -xrm '*menuBar: false' -xrm '*keypadOn: false' \
  -xrm '*font: fixed' -xrm '*labelFont: fixed' \
  -xrm '*visualBell: true' \
  "127.0.0.1:$PORT" &
XPID=$!
trap 'kill -TERM "$XPID" 2>/dev/null || true' EXIT TERM INT

xif() { x3270if -t "$SPORT" "$@" 2>/dev/null; }
screen() { xif 'Ascii()'; }

# the script port comes up a moment after the process does
for _ in $(seq 1 120); do
  kill -0 "$XPID" 2>/dev/null || {
    echo "mvs38-session: x3270 exited at startup" >&2
    exit 1
  }
  [ -n "$(xif 'Query(Model)')" ] && break
  sleep 0.25
done

logon() {
  local i s
  # Wait for the 3270 session itself, then for Hercules' device logo to have
  # been painted — Ascii() is empty until the first write reaches the screen.
  xif "Wait($TIMEOUT,3270Mode)" >/dev/null || return 1
  for _ in $(seq 1 "$TIMEOUT"); do
    [ -n "$(screen | tr -d ' \n')" ] && break
    sleep 1
  done

  # Clear, then ask VTAM for TSO. Clear is not decoration: the logo's fields are
  # PROTECTED, so typing into them only locks the keyboard (X SYSTEM); Clear
  # blanks the screen locally and unlocks it. MEASURED 2026-09-20 — this is
  # exactly the wall a visitor hits on the raw station.
  xif 'Clear()' >/dev/null
  xif 'String("TSO")' >/dev/null
  xif 'Enter()' >/dev/null

  wait_text() { # $1 extended regex
    local n=0
    while [ "$n" -lt "$TIMEOUT" ]; do
      screen | grep -qE "$1" && return 0
      sleep 1
      n=$((n + 1))
    done
    return 1
  }

  wait_text 'ENTER USERID' || return 1
  xif "String(\"$USER_ID\")" >/dev/null
  xif 'Enter()' >/dev/null

  wait_text 'ENTER CURRENT PASSWORD' || return 1
  xif "String(\"$(cat "$WORK/tso.pass")\")" >/dev/null
  xif 'Enter()' >/dev/null

  # TSO then shows the site welcome and a TK5 fortune, each ending in the `***`
  # "press Enter" prompt, before ISPLOGON starts ISPF. The count of those pages
  # is a TK5 customisation, not a constant, so this waits for the DESTINATION
  # and answers any `***` it meets on the way.
  for i in $(seq 1 "$TIMEOUT"); do
    s="$(screen)"
    case "$s" in *'ISPF primary option menu'*) return 0 ;; esac
    case "$s" in *'***'*) xif 'Enter()' >/dev/null ;; esac
    sleep 1
  done
  return 1
}

if [ -s "$WORK/tso.pass" ]; then
  if logon; then
    : >"$WORK/logon.ok"
    echo "mvs38-session: logged on as $USER_ID, ISPF primary option menu is on screen"
  else
    echo "mvs38-session: WARNING — the scripted TSO logon did not reach ISPF;" \
      "the terminal is live but the rest scene is wrong" >&2
    screen >&2
  fi
else
  echo "mvs38-session: no $WORK/tso.pass — leaving the terminal at the VTAM screen" >&2
fi

wait "$XPID"
