#!/bin/bash
# rn-tapnet.sh — the aix432 station's link onto the retronet bridge vmbr-rn.
#
# Bridge-enslaved sibling of streamhost/stations/hpuxvue/rn-tapnet.sh. The guest
# is AIX 4.3.3 on an emulated IBM RS/6000 7020 (40p); it shares L2 with the
# retronet gateway CT (10.99.0.2) so it gets real ICMP/UDP and multi-connection
# TCP straight to the gateway's :80 corpus origin. WEB PLANE ONLY — this guest
# has no OSCAR client, so it never joins the icq plane.
#
# The guest is a 1990s commercial Unix with the usual r-services, so containment
# is layered and does not depend on any one thing:
#
#   1. TOPOLOGY. The tap is enslaved ONLY to vmbr-rn, a bridge with
#      `bridge-ports none` and NO uplink. The guest is never on the LAN's L2.
#   2. ROUTING. The guest is configured with NO default route (static
#      10.99.0.28/24, gateway deliberately unset), so its own stack cannot form
#      a packet to anything off 10.99.0.0/24. labhost's `retronet-fw` FORWARD
#      chain drops anything trying to route THROUGH the box regardless.
#   3. FILTER. This station's own fail-closed INPUT chain (below), scoped to the
#      guest's source IP, lets the guest reach labhost ONLY as the ESTABLISHED
#      reply side of a labhost-initiated connection. Every NEW connection the
#      guest starts toward labhost is DROPPED — including the gallery on
#      10.99.0.1:8443, which no-default-route does NOT close because 10.99.0.1
#      is ON the guest's own subnet.
#
# CHAIN NAMING (the irix lesson, docs/lab/retronet/WEB-STATION-irix.md): the
# chain name is derived from the INTERFACE, not only the address. A bring-up
# clone on its own tap otherwise runs `down` and deletes the LIVE station's
# chain and its INPUT hook while every message reports success. The live station
# on aixrn0 owns the bare name AIXRN-IN; any other tap gets AIXRN-IN-<if>.
#
# Idempotent, and called `up` from qemu-streamhost.sh on EVERY launch — that is
# what makes it survive a station relaunch and a host reboot without a separate
# systemd unit. The tap is PERSISTENT: it is not torn down when QEMU stops.
#
#   rn-tapnet.sh up          create + enslave to vmbr-rn + install/verify guard
#   rn-tapnet.sh down        remove guard + unslave + delete the tap
#   rn-tapnet.sh show        current state
set -u

IF="${RN_TAP_IF:-aixrn0}"
BRIDGE="${RN_TAP_BRIDGE:-vmbr-rn}"
# The guest's STATIC address on vmbr-rn (AIX 4.3.3 is configured by hand; the
# DHCP reservation ledger in local.env still carries the MAC for uniqueness).
GUEST_IP="${RN_TAP_GUEST_IP:-10.99.0.28}"
# Interface-derived so a clone can never disarm the live exhibit (see above).
if [ "$IF" = "aixrn0" ]; then IN_CHAIN="AIXRN-IN"; else IN_CHAIN="AIXRN-IN-$IF"; fi
# Seconds to wait for the xtables lock: a lost race brings the tap up with NO
# fail-closed rules while every message still says "up", which is why
# install_rules is read back by verify_rules.
IPT_WAIT="${RN_TAP_IPT_WAIT:-15}"

msg() { echo "rn-tapnet: $*"; }
die() {
  echo "rn-tapnet: $*" >&2
  exit 1
}

install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -I INPUT 1 -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN"
}

verify_rules() {
  local s
  s="$(iptables -w "$IPT_WAIT" -S 2>/dev/null)" || return 1
  grep -qx -- "-A INPUT -s $GUEST_IP/32 -i $BRIDGE -j $IN_CHAIN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -j DROP" <<<"$s" || return 1
}

remove_rules() {
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -X "$IN_CHAIN" 2>/dev/null || true
}

do_up() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  case "$IF" in
    *[!a-zA-Z0-9_-]* | '') die "invalid interface name: $IF" ;;
  esac
  [ "${#IF}" -le 15 ] || die "interface name longer than 15 chars: $IF"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE is absent (Stream B provisions it)"
  if ! ip link show "$IF" >/dev/null 2>&1; then
    ip tuntap add dev "$IF" mode tap || die "could not create tap $IF"
    msg "created tap $IF"
  fi
  local cur
  cur="$(cat "/sys/class/net/$IF/master/ifindex" 2>/dev/null || echo '')"
  if [ "$(cat "/sys/class/net/$BRIDGE/ifindex" 2>/dev/null || echo x)" != "$cur" ]; then
    ip link set dev "$IF" master "$BRIDGE" || die "could not enslave $IF to $BRIDGE"
  fi
  sysctl -qw "net.ipv6.conf.$IF.disable_ipv6=1" 2>/dev/null || true
  ip link set dev "$IF" up
  install_rules
  if ! verify_rules; then
    install_rules # one retry: the usual cause is a lost xtables race, not a bad rule
    verify_rules || die "guest containment rules for $IF did not verify — refusing to report up"
  fi
  msg "up: $IF enslaved to $BRIDGE; guest $GUEST_IP contained via $IN_CHAIN"
}

do_down() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  remove_rules
  if ip link show "$IF" >/dev/null 2>&1; then
    ip link set dev "$IF" nomaster 2>/dev/null || true
    ip link del dev "$IF"
  fi
  msg "down: $IF removed (chain $IN_CHAIN)"
}

do_show() {
  ip -br addr show "$IF" 2>/dev/null || echo "$IF: absent"
  echo "master=$(basename "$(readlink "/sys/class/net/$IF/master" 2>/dev/null || echo none)")"
  echo "disable_ipv6=$(cat "/proc/sys/net/ipv6/conf/$IF/disable_ipv6" 2>/dev/null || echo '?')"
  iptables -w "$IPT_WAIT" -S "$IN_CHAIN" 2>/dev/null || echo "(no $IN_CHAIN)"
  iptables -w "$IPT_WAIT" -S INPUT | grep -- "$IN_CHAIN" || echo "(INPUT not hooked)"
}

case "${1:-}" in
  up) do_up ;;
  down) do_down ;;
  show) do_show ;;
  *)
    sed -n '2,30p' "$0" >&2
    exit 2
    ;;
esac
