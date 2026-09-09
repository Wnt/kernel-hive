#!/bin/bash
# rn-tapnet.sh — the slackware station's link onto the retronet bridge vmbr-rn.
#
# Sibling of streamhost/stations/chokanji/rn-tapnet.sh (the static-addressed variant;
# win98se is the DHCP pathfinder — docs/lab/retronet/ICQ-STATION.md has the full
# rationale). Same shape, different tap, chain and guest IP.
#
# The guest is Slackware 3.4 from October 1997: Linux 2.0.30, libc5, root with an EMPTY
# password, and — unlike every other static retronet station — an inetd with a telnetd
# behind it. That telnetd IS the station's exec channel (`labctl exec slackware`), which
# makes this link the one thing standing between a 1997 kernel and the rest of the box.
# Containment is layered and does NOT depend on any one thing:
#
#   1. TOPOLOGY. The tap is enslaved ONLY to vmbr-rn, which has `bridge-ports none`
#      and no uplink. The guest is never on the LAN's L2, so nothing on the LAN can
#      address it at all.
#   2. ROUTING. Slackware 3.4 predates DHCP on this media, so the guest is addressed
#      STATICALLY (compose.sh writes rc.inet1) and its no-default-route is the guest's
#      own config, not a withheld DHCP option 3 — rc.inet1 adds the on-link
#      10.99.0.0/24 route and NOTHING else. The reservation in
#      RETRONET_DHCP_RESERVATIONS exists only to keep the address unique fleet-wide.
#      labhost's `retronet-fw` FORWARD chain drops any vmbr-rn traffic that tries to
#      route THROUGH the box regardless.
#   3. FILTER. This station's own fail-closed INPUT chain (below), scoped to the
#      guest's source IP, drops every NEW connection the guest starts toward labhost.
#      Without it the guest could open labhost's 0.0.0.0 listeners by dialling the
#      bridge address 10.99.0.1, which retronet-fw deliberately leaves reachable
#      (`RETRONET-IN` returns -d 10.99.0.1), and no-default-route does not close that
#      because 10.99.0.1 is ON the guest's own subnet.
#   4. IN THE GUEST. tcpd's /etc/hosts.deny is `ALL: ALL` and /etc/hosts.allow lists
#      exactly `in.telnetd: 10.99.0.1`, so even from inside the bridge nobody but
#      labhost reaches the exec channel.
#
# DIFFERENCE FROM chokanji: labhost DOES dial this guest, twice, and both directions
# matter here. The daemon's x11warp absolute pointer opens the guest's X server at
# 10.99.0.31:6000 on every pointer motion, and `labctl exec` opens its telnetd at
# 10.99.0.31:23. Both are labhost-INITIATED, so the ESTABLISHED,RELATED RETURN rule
# below is load-bearing rather than a courtesy: without it the pointer stops working.
# The chain still refuses everything the guest itself starts.
#
# What this link DOES expose, stated plainly: the other guests on vmbr-rn can address
# 10.99.0.31, and what they would find is an X server with `xhost +10.99.0.1` (so an
# X connection from anywhere else is refused by the X server itself) and a telnetd
# behind tcpd's ALL: ALL deny. That is the accepted trade for being on the retronet at
# all, and it is the same trade every bridged station makes.
#
# Intra-bridge traffic (guest -> CT 10.99.0.2, for DNS + the :3128 corpus proxy + the
# UDP 4000 ICQ door) is pure L2 with bridge-nf-call-iptables=0, so it never touches
# these chains and is always allowed — that is the retronet reaching the retronet,
# which is the point.
#
# Idempotent, and called `up` from qemu-streamhost.sh on EVERY launch — that is what
# makes the containment a precondition of the guest running rather than a setup step
# somebody remembered.
#
# usage: rn-tapnet.sh up | down | show
set -u

IF="${RN_TAP_IF:-slackwarern0}"
BRIDGE="${RN_TAP_BRIDGE:-vmbr-rn}"
# The guest's statically configured address on vmbr-rn, reserved (but never
# claimed) in RETRONET_DHCP_RESERVATIONS so nothing else can take it. The guard
# chain is scoped to it,
# so the filter follows the guest, never the whole bridge.
GUEST_IP="${RN_TAP_GUEST_IP:-10.99.0.31}"
IN_CHAIN="SLACKWARERN-IN"
# Seconds to wait for the xtables lock (see irix/tapnet.sh for why this is not
# optional): a lost race brings the tap up with NO fail-closed rules while every
# message still says "up", which is why install_rules is read back by verify_rules.
IPT_WAIT="${RN_TAP_IPT_WAIT:-15}"

msg() { echo "rn-tapnet: $*"; }
die() {
  echo "rn-tapnet: $*" >&2
  exit 1
}

# Fail-closed filter: every NEW flow the guest starts toward labhost is dropped;
# only the reply side of a labhost-initiated flow returns. Rebuilt from empty
# on each call.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  # replies to something labhost dialled (debugging probes only — no exec channel).
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # everything else the guest initiates toward labhost — gallery :8443, ssh :22,
  # any 0.0.0.0 listener reachable via the bridge address — is refused.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # Hook the guest's source IP into INPUT, ABOVE retronet-fw's RETRONET-IN so the
  # scoped DROP wins over its blanket `-d 10.99.0.1 -j RETURN`. Re-inserted at 1
  # on every launch (post-boot), which keeps it above the boot-time RETRONET-IN.
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -I INPUT 1 -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN"
}

# Read the isolation back out of the kernel: install_rules cannot be trusted to
# have worked just because it ran (lock contention, a ruleset reload underneath).
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
  # PERSISTENT tap: it exists before QEMU starts and survives QEMU exiting, so
  # the link is not a function of process lifetime. QEMU attaches with
  # -netdev tap,ifname=$IF,script=no,downscript=no (it opens an existing tap).
  if ! ip link show "$IF" >/dev/null 2>&1; then
    ip tuntap add dev "$IF" mode tap || die "could not create tap $IF"
    msg "created tap $IF"
  fi
  # Enslave to the retronet bridge — the whole point of this variant. Idempotent:
  # `master` is a no-op if already set to $BRIDGE, and re-homes if it drifted.
  local cur
  cur="$(cat "/sys/class/net/$IF/master/ifindex" 2>/dev/null || echo '')"
  if [ "$(cat "/sys/class/net/$BRIDGE/ifindex" 2>/dev/null || echo x)" != "$cur" ]; then
    ip link set dev "$IF" master "$BRIDGE" || die "could not enslave $IF to $BRIDGE"
  fi
  # No L3 address on the tap: it is a pure bridge port. labhost reaches the guest
  # via the bridge's own 10.99.0.1. IPv6 off on the port for good measure
  # (retronet-fw drops vmbr-rn IPv6 anyway).
  sysctl -qw "net.ipv6.conf.$IF.disable_ipv6=1" 2>/dev/null || true
  ip link set dev "$IF" up
  install_rules
  if ! verify_rules; then
    install_rules # one retry: the usual cause is a lost xtables race, not a bad rule
    verify_rules || die "guest containment rules for $IF did not verify — refusing to report up"
  fi
  msg "up: $IF enslaved to $BRIDGE; guest $GUEST_IP contained (NEW->labhost dropped)"
}

do_down() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  remove_rules
  if ip link show "$IF" >/dev/null 2>&1; then
    ip link set dev "$IF" nomaster 2>/dev/null || true
    ip link del dev "$IF"
  fi
  msg "down: $IF removed"
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
