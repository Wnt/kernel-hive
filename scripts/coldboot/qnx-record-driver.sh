#!/bin/bash
# Automated, clone-only QNX 6.5 LiveCD landing sequence for record-boot.sh.
# No human input: wait for the real framebuffer states, then use the clone QMP.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bootrec-lib.sh disable=SC1091
source "${BOOTREC_LIB:-$HERE/bootrec-lib.sh}"

QMP="${1:?qmp.sock required}"
WORK="${2:?workdir required}/qnx-driver"
PASSWORD="${QNX_RECORD_PASSWORD:-}"
mkdir -p "$WORK"

dims() { identify -format '%wx%h' "$1" 2>/dev/null || true; }
send() { br_hmp "$QMP" "sendkey $1" >/dev/null; }

# The early hardware scan and the actual Select? menu are both 720x400. Avoid
# racing F2 into the scan by requiring a stable framebuffer after a 25 s floor.
sleep 25
prev=""
stable=0
for i in $(seq 1 35); do
  shot="$WORK/menu-$i.png"
  br_screendump "$QMP" "$shot" || {
    sleep 2
    continue
  }
  sum="$(md5sum "$shot" | awk '{print $1}')"
  if [ "$(dims "$shot")" = "720x400" ] && [ "$sum" = "$prev" ]; then
    stable=$((stable + 1))
  else
    stable=0
  fi
  [ "$stable" -ge 2 ] && break
  prev="$sum"
  sleep 2
done
[ "$stable" -ge 2 ] || br_die "qnx driver: stable 720x400 Select? menu not reached"
send f2

# Photon/phgrafx switches away from 720x400. A fresh cirrus/devg-svga pass starts
# at 640x480; select 1024x768 and accept the timed mode test by Alt+A.
graphical=0
for i in $(seq 1 50); do
  shot="$WORK/photon-$i.png"
  br_screendump "$QMP" "$shot" || {
    sleep 2
    continue
  }
  case "$(dims "$shot")" in 640x480 | 800x600 | 1024x768)
    graphical=1
    break
    ;;
  esac
  sleep 2
done
[ "$graphical" -eq 1 ] || br_die "qnx driver: Photon display wizard not reached"

for key in tab tab tab down down tab tab tab tab tab spc; do
  send "$key"
  sleep .3
done
sleep 2
send alt-a
sleep 12
br_screendump "$QMP" "$WORK/mode-accepted.png" || br_die "qnx driver: mode proof failed"
[ "$(dims "$WORK/mode-accepted.png")" = "1024x768" ] || br_die "qnx driver: 1024x768 was not accepted"

# Exit phgrafx by mnemonic, then log in as root. The LiveCD password is empty;
# QNX_RECORD_PASSWORD remains an optional non-echoed override for local media.
send alt-x
sleep 5
for k in r o o t; do send "$k"; done
send ret
sleep 1
for ((i = 0; i < ${#PASSWORD}; i++)); do
  k="${PASSWORD:i:1}"
  [[ "$k" =~ [A-Za-z0-9] ]] || br_die "qnx driver: password must be alphanumeric for HMP sendkey"
  send "${k,,}"
done
send ret
sleep 12
br_screendump "$QMP" "$WORK/ready.png" || br_die "qnx driver: final framebuffer capture failed"
[ "$(dims "$WORK/ready.png")" = "1024x768" ] || br_die "qnx driver: final framebuffer is not 1024x768 Photon"
