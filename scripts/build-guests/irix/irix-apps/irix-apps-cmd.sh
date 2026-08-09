#!/usr/bin/env bash
# Drive the Track A install rig: one command per invocation, appended to the
# agent's command file. See irix-apps-agent.lua for the verb list.
#
#   irix-apps-cmd.sh line "<shell line>"   type a shell line + Enter (POST+CODE)
#   irix-apps-cmd.sh post "<text>"         type text, no Enter
#   irix-apps-cmd.sh slow "<text>"         type char-by-char (login-name widget
#                                          drops fast natkeyboard chars)
#   irix-apps-cmd.sh code "{ENTER}"        coded keys
#   irix-apps-cmd.sh click1|click2|click3|dclick1|down1|up1
#   irix-apps-cmd.sh cd <iso-basename>     swap the CD without restarting MAME
#   irix-apps-cmd.sh eject|cdinfo|snap|dump|reset|exit
#   irix-apps-cmd.sh raw "<VERB args>"     anything else
set -u
D="${IRIX_APPS_DIR:-/data/vms/soltest/irix-apps}"
CMD="$D/irix_cmd"
send() { printf '%s\n' "$1" >>"$CMD"; }

verb="${1:?usage: irix-apps-cmd.sh <verb> [arg]}"
arg="${2:-}"
case "$verb" in
  line)
    send "POST $arg"
    sleep 0.4
    send "CODE {ENTER}"
    ;;
  post) send "POST $arg" ;;
  mixed)
    # The emulated keyboard is a PC keyboard behind an SGI keymap: SHIFTED
    # characters never arrive (uppercase silently lowercases, "_ | ~ > <" vanish),
    # but CAPS LOCK does work. Type mixed-case text by toggling caps around the
    # uppercase runs. Shifted SYMBOLS remain impossible -- put those in a script
    # on the kit ISO instead.
    caps=0
    for ((i = 0; i < ${#arg}; i++)); do
      ch="${arg:$i:1}"
      case "$ch" in
        [A-Z])
          [ "$caps" = 0 ] && {
            send "CODE {CAPSLOCK}"
            caps=1
            sleep 0.4
          }
          send "POST ${ch}"
          ;;
        *)
          [ "$caps" = 1 ] && {
            send "CODE {CAPSLOCK}"
            caps=0
            sleep 0.4
          }
          send "POST ${ch}"
          ;;
      esac
      sleep 0.35
    done
    [ "$caps" = 1 ] && send "CODE {CAPSLOCK}"
    ;;
  mixedline)
    "$0" mixed "$arg"
    sleep 0.6
    send "CODE {ENTER}"
    ;;
  caps) send "CODE {CAPSLOCK}" ;;
  slow)
    for ((i = 0; i < ${#arg}; i++)); do
      send "POST ${arg:$i:1}"
      sleep 0.4
    done
    ;;
  code) send "CODE $arg" ;;
  click1) send CLICK1 ;;
  click2) send CLICK2 ;;
  click3) send CLICK3 ;;
  dclick1) send DCLICK1 ;;
  down1) send DOWN1 ;;
  up1) send UP1 ;;
  cd) send "CDLOAD $D/media/$arg" ;;
  eject) send CDEJECT ;;
  cdinfo) send CDINFO ;;
  kbdinfo) send KBDINFO ;;
  kbsgi) send KBSGI ;;
  kbps2) send KBPS2 ;;
  lua) send "LUA $arg" ;;
  snap) send SNAP ;;
  dump) send DUMP ;;
  reset) send RESET ;;
  exit) send EXIT ;;
  raw) send "$arg" ;;
  *)
    echo "unknown verb: $verb" >&2
    exit 2
    ;;
esac
