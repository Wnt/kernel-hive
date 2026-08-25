#!/bin/bash
# rn-netns.sh — the amigaos35 station's link onto the retronet bridge vmbr-rn.
#
# Sibling of streamhost/stations/irix/rn-tapnet.sh, with one structural
# difference: FS-UAE has no tap/pcap backend (the Debian build's A2065/NE2000
# host side is winpcap-only and libpcap is not linked), and its networking is
# `bsdsocket_library=1` — the emulated bsdsocket.library backed by the HOST
# process's own sockets. Bare, that would put the Amiga's traffic on labhost's
# stack: no station identity, no containment. So the cage is a NETWORK
# NAMESPACE: the launcher runs fs-uae inside netns $NS, whose ONLY interface
# is the guest end of a veth pair whose host end is enslaved to vmbr-rn.
# Everything the Amiga's bsdsocket does — TCP, UDP, and the host-side
# gethostbyname() (which reads the netns' own resolv.conf → 10.99.0.2) —
# happens at the station's IP/MAC on the museum bridge, exactly like a tap
# guest.
#
# Containment layers (same three as every bridged station):
#   1. TOPOLOGY  vmbr-rn has bridge-ports none — no uplink, never the LAN's L2.
#   2. ROUTING   the netns has ONLY the 10.99.0.0/24 link route: no default
#                route exists, so the stack cannot form a packet to anything
#                off the plane. (Stronger than a guest-side config: the
#                emulated OS cannot add a route the netns does not have.)
#   3. FILTER    fail-closed INPUT chain below, scoped to the guest IP, above
#                RETRONET-IN — labhost's own 10.99.0.1 listeners stay closed
#                to flows the station starts.
#
# The guest MAC rides the veth guest end and follows the fleet scheme
# (52:54:00:52:4e:<ip-hex>); the real value lives ONLY in gitignored
# registry/local.env as RN_AMIGAOS35_MAC — the committed placeholder below is
# scrubbed per AGENTS.md rule 1.
#
# Idempotent; called `up` from x11-runtime.sh on every launch when
# FSUAE_NATIVE_NET=bsdsocket. `down` is for teardown by hand.
#
#   rn-netns.sh up      netns + veth + bridge port + resolv.conf + guard
#   rn-netns.sh down    remove guard + veth + netns
#   rn-netns.sh show    current state
set -u

NS="${RN_NS:-rn-amigaos35}"
IF_H="${RN_VETH_HOST:-amiga35-h}"
IF_G="${RN_VETH_GUEST:-amiga35-g}"
BRIDGE="${RN_BRIDGE:-vmbr-rn}"
GUEST_IP="${RN_GUEST_IP:-10.99.0.26}"
DNS_IP="${RN_DNS_IP:-10.99.0.2}"
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
GUEST_MAC="02:00:00:00:00:1a" # placeholder (committed); real value in local.env
_m="$(sed -n 's/^RN_AMIGAOS35_MAC=//p' "$RN_LOCAL_ENV" 2>/dev/null | head -1)"
[ -n "$_m" ] && GUEST_MAC="$_m"

# PER-INTERFACE chain name — the clone-teardown containment lesson
# (streamhost/stations/irix/rn-tapnet.sh header, commit 9e7cc64): the
# production veth keeps the bare registry name, anything else is suffixed.
if [ -n "${RN_IN_CHAIN:-}" ]; then
  IN_CHAIN="$RN_IN_CHAIN"
elif [ "$IF_H" = amiga35-h ]; then
  IN_CHAIN="AMIGAOS35RN-IN"
else
  IN_CHAIN="AMIGAOS35RN-IN-$IF_H"
fi
IPT_WAIT="${RN_IPT_WAIT:-15}"

msg() { echo "rn-netns: $*"; }
die() {
  echo "rn-netns: $*" >&2
  exit 1
}
[ "${#IN_CHAIN}" -le 28 ] || die "chain name longer than 28 chars: $IN_CHAIN"

install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -I INPUT 1 -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN"
}

# Read the isolation back out of the kernel — install_rules ran is not
# install_rules worked (xtables lock race, ruleset reload underneath).
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
  [ "${#IF_H}" -le 15 ] && [ "${#IF_G}" -le 15 ] || die "veth name longer than 15 chars"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE is absent (the gateway provisioner makes it)"
  ip netns list 2>/dev/null | grep -qw "$NS" || {
    ip netns add "$NS" || die "could not create netns $NS"
    msg "created netns $NS"
  }
  # Host-side resolv.conf for the netns: ip netns exec bind-mounts it over
  # /etc/resolv.conf, which is what bsdsocket's host-side resolver reads.
  install -d "/etc/netns/$NS"
  printf 'nameserver %s\nsearch retronet.lab\n' "$DNS_IP" >"/etc/netns/$NS/resolv.conf"
  if ! ip link show "$IF_H" >/dev/null 2>&1; then
    ip link add "$IF_H" type veth peer name "$IF_G" || die "could not create veth pair"
    msg "created veth $IF_H <-> $IF_G"
  fi
  # Guest end into the netns (idempotent: absent from the host view = already moved).
  if ip link show "$IF_G" >/dev/null 2>&1; then
    ip link set "$IF_G" netns "$NS" || die "could not move $IF_G into $NS"
  fi
  ip netns exec "$NS" ip link set "$IF_G" address "$GUEST_MAC"
  ip netns exec "$NS" ip addr replace "$GUEST_IP/24" dev "$IF_G"
  ip netns exec "$NS" ip link set lo up
  ip netns exec "$NS" ip link set "$IF_G" up
  # NO default route is added — layer 2 of the containment. Verify, don't assume.
  if ip netns exec "$NS" ip route show default 2>/dev/null | grep -q .; then
    die "netns $NS unexpectedly has a default route — refusing"
  fi
  local cur
  cur="$(cat "/sys/class/net/$IF_H/master/ifindex" 2>/dev/null || echo '')"
  if [ "$(cat "/sys/class/net/$BRIDGE/ifindex" 2>/dev/null || echo x)" != "$cur" ]; then
    ip link set dev "$IF_H" master "$BRIDGE" || die "could not enslave $IF_H to $BRIDGE"
  fi
  sysctl -qw "net.ipv6.conf.$IF_H.disable_ipv6=1" 2>/dev/null || true
  ip netns exec "$NS" sysctl -qw "net.ipv6.conf.$IF_G.disable_ipv6=1" 2>/dev/null || true
  # es40 lesson kept even though bsdsocket never sees these frames: checksum
  # offload off on both veth ends so any pcap-class reader gets sane frames.
  ethtool -K "$IF_H" tx off rx off >/dev/null 2>&1 || true
  ip netns exec "$NS" ethtool -K "$IF_G" tx off rx off >/dev/null 2>&1 || true
  ip link set dev "$IF_H" up
  install_rules
  if ! verify_rules; then
    install_rules
    verify_rules || die "guest containment rules for $GUEST_IP did not verify — refusing to report up"
  fi
  msg "up: $NS via $IF_H on $BRIDGE; guest $GUEST_IP ($GUEST_MAC) contained (no default route; NEW->labhost dropped)"
}

do_down() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  remove_rules
  ip link del "$IF_H" 2>/dev/null || true
  ip netns del "$NS" 2>/dev/null || true
  rm -rf "/etc/netns/$NS"
  msg "down: $NS and $IF_H removed"
}

do_show() {
  ip netns list 2>/dev/null | grep -w "$NS" || echo "$NS: absent"
  ip -br link show "$IF_H" 2>/dev/null || echo "$IF_H: absent"
  ip netns exec "$NS" ip -br addr show "$IF_G" 2>/dev/null || echo "$IF_G: absent"
  ip netns exec "$NS" ip route show 2>/dev/null || true
  iptables -w "$IPT_WAIT" -S "$IN_CHAIN" 2>/dev/null || echo "(no $IN_CHAIN)"
  iptables -w "$IPT_WAIT" -S INPUT | grep -- "$IN_CHAIN" || echo "(INPUT not hooked)"
}

case "${1:-}" in
  up) do_up ;;
  down) do_down ;;
  show) do_show ;;
  *)
    sed -n '2,36p' "$0" >&2
    exit 2
    ;;
esac
