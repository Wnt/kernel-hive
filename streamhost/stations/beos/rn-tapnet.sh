#!/bin/bash
# rn-tapnet.sh — the beos station's link onto the retronet bridge vmbr-rn.
#
# The BeOS R5 sibling of streamhost/stations/win98se/rn-tapnet.sh and
# streamhost/stations/solaris/rn-tapnet.sh. Those proved the host-side pattern
# (a persistent tap enslaved to vmbr-rn + a fail-closed per-guest containment
# chain); this is the same host-side wiring for the BeOS R5 guest, which joined
# the retronet on 2026-08-22 so that NetPositive — R5's own browser — can reach
# the gateway's :80 museum-corpus origin over real L2 instead of slirp. See
# docs/lab/retronet/STATION-beos.md, ICQ-STATION.md (the win98se pathfinder) and
# ICQ-STATION-solaris.md.
#
# Containment is layered and does NOT depend on any one thing:
#
#   1. TOPOLOGY. The tap is enslaved ONLY to vmbr-rn, a bridge with
#      `bridge-ports none` and NO uplink. The guest is never on the LAN's L2.
#   2. ROUTING. The guest has NO default route (Lock 1). It is a DHCP client and
#      retronet-dhcp deliberately withholds option 3 (router), so the lease
#      itself carries an IP + mask + DNS and nothing to route through: the R5
#      stack cannot form a packet to anything off 10.99.0.0/24. labhost's
#      `retronet-fw` FORWARD chain (Lock 2, Stream B) drops any vmbr-rn traffic
#      that tries to route THROUGH the box regardless.
#   3. FILTER. This station's own fail-closed INPUT chain (below), scoped to the
#      guest's source IP, lets the guest reach labhost ONLY as the ESTABLISHED
#      reply side of a labhost-initiated connection. Every NEW connection the
#      guest starts toward labhost — the gallery on 10.99.0.1:8443, sshd,
#      anything bound to the bridge address — is DROPPED. Without this the guest
#      could open labhost's 0.0.0.0 listeners by dialling the bridge address,
#      which retronet-fw deliberately leaves reachable (`RETRONET-IN` returns
#      -d 10.99.0.1), and no-default-route does not close that because
#      10.99.0.1 is ON the guest's own subnet.
#
# beos' exec channel is BeOS R5's own telnetd, and it is labhost-INITIATED
# (labctl dials the guest at 10.99.0.16:23), so the guest never needs to start a
# flow toward labhost: the ESTABLISHED,RELATED return path is all it legitimately
# uses, and everything the guest itself initiates toward labhost is dropped.
# Intra-bridge traffic (guest -> CT 10.99.0.2, for DNS + the corpus web) is pure
# L2 with bridge-nf-call-iptables=0, so it never touches these chains and is
# always allowed — the retronet reaching the retronet.
#
# Idempotent, and called `up` from qemu-streamhost.sh on EVERY launch — that is
# what makes it survive a station relaunch and a host reboot without a separate
# systemd unit, exactly like win98se/rn-tapnet.sh. The tap is PERSISTENT: it is
# not torn down when QEMU stops (the guard chain then simply contains a guest
# that is not there). `down` is for teardown by hand.
#
#   rn-tapnet.sh up          create + enslave to vmbr-rn + install/verify guard
#   rn-tapnet.sh down        remove guard + unslave + delete the tap
#   rn-tapnet.sh show        current state
set -u

IF="${RN_TAP_IF:-beosrn0}"
BRIDGE="${RN_TAP_BRIDGE:-vmbr-rn}"
# The guest's address on vmbr-rn: DHCP, but RESERVED for this station's MAC by
# retronet-dhcp, so it is stable. The guard chain is scoped to it, so the filter
# follows the guest, never the whole bridge.
GUEST_IP="${RN_TAP_GUEST_IP:-10.99.0.16}"
IN_CHAIN="BEOSRN-IN"
# The guest's unique MAC on vmbr-rn -- the SECOND thing the guard chain is scoped
# to (see install_rules for why the IP alone is not enough). Real value is
# box-local in registry/local.env RN_BEOS_MAC, exactly as the launcher reads it;
# the committed fallback is the scrubbed placeholder.
GUEST_MAC="${RN_TAP_GUEST_MAC:-$(sed -n 's/^[[:space:]]*RN_BEOS_MAC=//p' /data/kernel-hive/registry/local.env 2>/dev/null | tail -1 | tr -d '\042\047')}"
GUEST_MAC="${GUEST_MAC:-02:00:00:00:00:10}"
# Seconds to wait for the xtables lock (see win98se/rn-tapnet.sh for why this is
# not optional): a lost race brings the tap up with NO fail-closed rules while
# every message still says "up", which is why install_rules is read back by
# verify_rules.
IPT_WAIT="${RN_TAP_IPT_WAIT:-15}"

msg() { echo "rn-tapnet: $*"; }
die() {
  echo "rn-tapnet: $*" >&2
  exit 1
}

# Fail-closed filter: the guest may talk to labhost ONLY as the reply side of a
# connection labhost opened (the exec channel, labhost -> guest:7777). Every NEW
# flow the guest starts toward labhost is dropped. Rebuilt from empty each call.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  # exec replies (labhost dialled the guest; this is the return traffic).
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # everything else the guest initiates toward labhost — gallery :8443, ssh :22,
  # any 0.0.0.0 listener reachable via the bridge address — is refused.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # Hook the guest into INPUT, ABOVE retronet-fw's RETRONET-IN so the scoped DROP
  # wins over its blanket `-d 10.99.0.1 -j RETURN`. Re-inserted at 1 on every
  # launch (post-boot), which keeps it above the boot-time RETRONET-IN.
  #
  # TWO hooks, deliberately. The fleet convention is to scope the chain to the
  # guest's IP, and that is the first rule. But an IP-scoped chain contains the
  # guest only for as long as the guest keeps the IP we expect, and on
  # 2026-08-23 this station demonstrated exactly that hole: after a WARM
  # `system_reset` (as opposed to a QEMU restart) R5's dhcp_client sent its
  # DISCOVER with an all-zero chaddr, retronet-dhcp could not match the
  # reservation, and the guest came up on a POOL address -- still route-less, so
  # still no WAN, but no longer matched by an -s 10.99.0.16 rule, i.e. free to
  # dial labhost's own listeners. The second hook scopes the SAME fail-closed
  # chain to the guest's source MAC, which is the station's stable identity: the
  # NIC keeps transmitting with it even when the DHCP payload does not carry it,
  # so containment follows the guest to whatever address it ends up on.
  # (physdev matching would be the obvious alternative and does NOT work here:
  # the box runs bridge-nf-call-iptables=0, so nothing populates physdev.)
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN" 2>/dev/null; do :; done
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -m mac --mac-source "$GUEST_MAC" -j "$IN_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -I INPUT 1 -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN"
  iptables -w "$IPT_WAIT" -I INPUT 1 -i "$BRIDGE" -m mac --mac-source "$GUEST_MAC" -j "$IN_CHAIN"
}

# Read the isolation back out of the kernel: install_rules cannot be trusted to
# have worked just because it ran (lock contention, a ruleset reload underneath).
verify_rules() {
  local s
  s="$(iptables -w "$IPT_WAIT" -S 2>/dev/null)" || return 1
  grep -qx -- "-A INPUT -s $GUEST_IP/32 -i $BRIDGE -j $IN_CHAIN" <<<"$s" || return 1
  grep -qix -- "-A INPUT -i $BRIDGE -m mac --mac-source $GUEST_MAC -j $IN_CHAIN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -j DROP" <<<"$s" || return 1
}

remove_rules() {
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN" 2>/dev/null; do :; done
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -m mac --mac-source "$GUEST_MAC" -j "$IN_CHAIN" 2>/dev/null; do :; done
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
  msg "up: $IF enslaved to $BRIDGE; guest $GUEST_IP contained (exec replies only toward labhost; NEW->labhost dropped)"
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
  echo "guest_mac=$GUEST_MAC"
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
