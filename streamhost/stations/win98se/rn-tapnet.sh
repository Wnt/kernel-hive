#!/bin/bash
# rn-tapnet.sh — the win98se station's link onto the retronet bridge vmbr-rn.
#
# This is the BRIDGE-enslaved cousin of streamhost/stations/irix/tapnet.sh. The
# irix tap is a host-only /30 that REFUSES to ever be a bridge port; this one is
# the opposite by design — the Win98 guest must share L2 with the retronet
# gateway CT (10.99.0.2) so its ICQ 2000b client gets working UDP + ICMP and
# real multi-connection TCP straight to the OSCAR server (what slirp's
# single-connection guestfwd could not carry). See docs/lab/retronet/ICQ-STATION.md.
#
# The guest is Windows 98 SE — an unpatched 1999 TCP/IP stack with SMB and other
# listeners. A bridged Win98 is real exposure, so containment is layered and does
# NOT depend on any one thing:
#
#   1. TOPOLOGY. The tap is enslaved ONLY to vmbr-rn, a bridge with
#      `bridge-ports none` and NO uplink. The guest is never on the LAN's L2.
#   2. ROUTING. The guest is configured with NO default route (Lock 1), so its
#      own stack cannot form a packet to anything off 10.99.0.0/24. labhost's
#      `retronet-fw` FORWARD chain (Lock 2, Stream B) drops any vmbr-rn traffic
#      that tries to route THROUGH the box regardless.
#   3. FILTER. This station's own fail-closed INPUT chain (below), scoped to the
#      guest's source IP, lets the guest reach labhost ONLY as the ESTABLISHED
#      reply side of a labhost-initiated connection (the exec channel). Every
#      NEW connection the guest starts toward labhost — the gallery on
#      10.99.0.1:8443, sshd, anything bound to the bridge address — is DROPPED.
#      Without this the guest could open labhost's 0.0.0.0 listeners by dialling
#      the bridge address, which retronet-fw deliberately leaves reachable
#      (`RETRONET-IN` returns -d 10.99.0.1), and no-default-route does not close
#      because 10.99.0.1 is ON the guest's own subnet.
#
# Intra-bridge traffic (guest -> CT 10.99.0.2, for ICQ + ping) is pure L2 with
# bridge-nf-call-iptables=0, so it never touches these chains and is always
# allowed — that is the retronet reaching the retronet, which is the point.
#
# Idempotent, and called `up` from qemu-streamhost.sh on EVERY launch — that is
# what makes it survive a station relaunch and a host reboot without a separate
# systemd unit, exactly like irix/tapnet.sh. The tap is PERSISTENT and is the
# station's deliverable: it is not torn down when QEMU stops (the guard chain
# then simply contains a guest that is not there). `down` is for teardown by hand.
#
#   rn-tapnet.sh up          create + enslave to vmbr-rn + install/verify guard
#   rn-tapnet.sh down        remove guard + unslave + delete the tap
#   rn-tapnet.sh show        current state
set -u

IF="${RN_TAP_IF:-win98rn0}"
BRIDGE="${RN_TAP_BRIDGE:-vmbr-rn}"
# The guest's static address on vmbr-rn. The guard chain is scoped to it, so the
# filter follows the guest, never the whole bridge.
GUEST_IP="${RN_TAP_GUEST_IP:-10.99.0.10}"
IN_CHAIN="WIN98RN-IN"
# Seconds to wait for the xtables lock (see irix/tapnet.sh for why this is not
# optional): a lost race brings the tap up with NO fail-closed rules while every
# message still says "up", which is why install_rules is read back by verify_rules.
IPT_WAIT="${RN_TAP_IPT_WAIT:-15}"

msg() { echo "rn-tapnet: $*"; }
die() {
  echo "rn-tapnet: $*" >&2
  exit 1
}

# Fail-closed filter: the guest may talk to labhost ONLY as the reply side of a
# connection labhost opened (the exec channel, labhost -> guest:7788). Every NEW
# flow the guest starts toward labhost is dropped. Rebuilt from empty each call.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  # exec replies (labhost dialled the guest; this is the return traffic).
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
