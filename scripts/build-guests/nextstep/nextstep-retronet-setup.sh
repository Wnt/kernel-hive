#!/bin/bash
# nextstep-retronet-setup.sh — everything that has to change INSIDE NeXTSTEP 3.3
# to put the guest on the retronet web plane, as one replayable pass.
#
# Runs on labhost. Drives the guest over its telnet exec channel with
# scripts/build-guests/nextstep-nstel.py, which is the only captured-output
# channel NeXTSTEP has (labctl exec reaches the kiosk, not the NeXT).
#
#   NSTEL_HOST=127.0.0.1 NSTEL_PORT=42323 nextstep-retronet-setup.sh all
#       during bring-up, through Previous's fixed SLIRP redirect
#   NSTEL_HOST=10.99.0.25 NSTEL_PORT=23  nextstep-retronet-setup.sh verify
#       afterwards, over the retronet itself
#
# Steps are separate and each is idempotent, so a re-run is the repair path.
#
# THREE THINGS THAT LOOK OPTIONAL AND ARE NOT
#
# 1. `netinfo` MUST run before the guest is ever booted on the bridge. A stock
#    NeXTSTEP 3.3 has /machines/broadcasthost with `serves = ../network`, which
#    tells netinfod to BROADCAST for a parent NetInfo domain. On SLIRP that
#    fails fast; on a real bridge with fourteen other stations it never
#    resolves, and the boot stops at a full-screen console panel — "Still
#    searching for parent network administration (NetInfo) server ... press 'c'
#    to continue" — with no telnetd, because inetd is started after it. Pressing
#    'c' does NOT rescue the boot: rc skips the rest of the network start and
#    the station comes up to a desktop with no listeners at all. Removing the
#    `serves` property is what makes an unattended bridge boot possible, and it
#    also stops the guest broadcasting RPC portmap onto the retronet forever.
#
# 2. `net` writes /etc/hostconfig, NOT an ifconfig line. NeXTSTEP 3.3 predates
#    DHCP; `-AUTOMATIC-` means BOOTP, which the retronet deliberately does not
#    answer (the gateway's DHCP server hands out addresses, and this station is
#    a static join). ROUTER=-NO- is Containment Lock 1 from inside the guest.
#
# 3a. NeXTSTEP's ping takes NO -c: it is `ping host [datasize] [npackets]`, and
#    `ping -c 3 10.99.0.2` treats "-c" as the HOSTNAME, floods, and prints
#    "sendto: Network is unreachable" forever — which reads exactly like a
#    routing failure on a station whose routing is the thing under test.
#
# 3. `defaults` MUST NOT run under `su`. The NeXTSTEP defaults database is
#    per-effective-user, so a `dwrite` from a telnet session that has su'd to
#    root writes ROOT's defaults and the console user `me` never sees them —
#    while `dread` in the same session reads them straight back and everything
#    looks correct. This cost a debug cycle here and the identical trap cost one
#    on rhapsody (docs/lab/retronet/WEB-BROWSER-rhapsody.md).
set -u

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
NSTEL="${NSTEL_PY:-$REPO/scripts/build-guests/nextstep-nstel.py}"
export NSTEL_HOST="${NSTEL_HOST:-127.0.0.1}"
export NSTEL_PORT="${NSTEL_PORT:-42323}"

GUEST_IP="${RN_GUEST_IP:-10.99.0.25}"
GUEST_NAME="${RN_GUEST_NAME:-nextstep}"
GUEST_MASK="${RN_GUEST_MASK:-255.255.255.0}"
GATEWAY="${RN_GATEWAY:-10.99.0.2}"
HOMEPAGE="${RN_HOMEPAGE:-http://www.apple.com/}"
SEARCHPAGE="${RN_SEARCHPAGE:-http://search.retronet/}"
# The payload the guest pulls over TFTP (see tinytftpd, below) — OmniWeb 2.7b3
# for NEXTSTEP, the `-N` (NeXT/m68k) slice of the Omni Group's own archive.
PAYLOAD="${RN_PAYLOAD:-OmniWeb-2.7b3-N.tar.gz}"
TFTP_HOST="${RN_TFTP_HOST:-10.0.2.2}" # SLIRP's view of the host
TFTP_PORT="${RN_TFTP_PORT:-6969}"

say() { echo "== $*"; }
# Every guest command is ONE LINE: root's shell is csh, so `2>&1` is a syntax
# error there and a heredoc pushed down this channel is parsed line by line.
asroot() { python3 "$NSTEL" me "$@"; }
asme() { python3 "$NSTEL" me --nosu "$@"; }

step_netinfo() {
  say "netinfo: stop the parent-domain broadcast search (see note 1)"
  asroot "niutil -destroyprop . /machines/broadcasthost serves" \
    "nidump -r /machines ."
}

step_net() {
  say "net: static $GUEST_IP/$GUEST_MASK, NO default route, DNS $GATEWAY"
  asroot "test -f /etc/hostconfig.preretronet || cp /etc/hostconfig /etc/hostconfig.preretronet" \
    "sed -e 's/^HOSTNAME=.*/HOSTNAME=$GUEST_NAME/' -e 's/^INETADDR=.*/INETADDR=$GUEST_IP/' -e 's/^ROUTER=.*/ROUTER=-NO-/' -e 's/^IPNETMASK=.*/IPNETMASK=$GUEST_MASK/' -e 's/^TIME=.*/TIME=-NO-/' /etc/hostconfig.preretronet > /etc/hostconfig" \
    "grep -v '^#' /etc/hostconfig" \
    "echo 'nameserver $GATEWAY' > /etc/resolv.conf" \
    "cat /etc/resolv.conf"
  # The gateway's wildcard DNS answers EVERY name with itself, this guest's own
  # hostname included, so the machine must be able to name itself locally.
  # NetInfo is consulted before DNS, and /etc/hosts is not consulted at all
  # while NetInfo runs — which its own comment header says out loud.
  asroot "niutil -create . /machines/$GUEST_NAME" \
    "niutil -createprop . /machines/$GUEST_NAME ip_address $GUEST_IP" \
    "niutil -createprop . /machines/$GUEST_NAME serves ./local" \
    "nidump -r /machines ."
}

step_browser() {
  say "browser: pull $PAYLOAD over TFTP and install OmniWeb"
  # TFTP, not FTP: NeXTSTEP 3.3's /usr/ucb/ftp has no `passive` command, and
  # active mode needs the server to dial the guest, which SLIRP cannot do
  # outside its fixed low-port redirect list. TFTP is guest-initiated UDP.
  asroot "cd /me && (echo binary; echo 'connect $TFTP_HOST $TFTP_PORT'; echo 'get $PAYLOAD'; echo quit) | tftp" \
    "ls -la /me/$PAYLOAD" \
    "cd /me && gzip -dc $PAYLOAD | gnutar xf -" \
    "test -d /LocalApps || mkdir /LocalApps" \
    "rm -rf /LocalApps/OmniWeb.app" \
    "cd /me && gnutar cf - OmniWeb.app | (cd /LocalApps && gnutar xf -)" \
    "chown -R me /me/OmniWeb.app" \
    "rm -f /me/$PAYLOAD" \
    "file /me/OmniWeb.app/OmniWeb" \
    "ls -ld /me/OmniWeb.app /LocalApps/OmniWeb.app"
}

step_defaults() {
  say "defaults: OmniWeb home page (as 'me', NOT under su — see note 3)"
  asme "whoami" \
    "dwrite OmniWeb HomePage $HOMEPAGE" \
    "dwrite OmniWeb ShowHomePage YES" \
    "dwrite OmniWeb SearchPage $SEARCHPAGE" \
    "dread OmniWeb HomePage" \
    "dread OmniWeb ShowHomePage"
}

step_verify() {
  say "verify: from inside the guest"
  asroot "hostname" \
    "/usr/etc/ifconfig en0" \
    "netstat -rn" \
    "ping $GATEWAY 56 3" \
    "ping www.apple.com 56 2" \
    "(echo 'GET / HTTP/1.0'; echo 'Host: www.apple.com'; echo '') | telnet $GATEWAY 80 | head -12" \
    "cat /etc/resolv.conf" \
    "ls -ld /LocalApps/OmniWeb.app"
}

case "${1:-}" in
  netinfo) step_netinfo ;;
  net) step_net ;;
  browser) step_browser ;;
  defaults) step_defaults ;;
  verify) step_verify ;;
  all)
    step_netinfo
    step_browser
    step_defaults
    step_net
    ;;
  *)
    sed -n '2,40p' "$0" >&2
    exit 2
    ;;
esac
