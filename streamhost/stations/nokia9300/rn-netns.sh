#!/bin/bash
# rn-netns.sh — a nokia9300-family station's link onto the retronet bridge vmbr-rn.
#
# Emitted from streamhost/stations/nokia9300/ for nokia9300 and for any rig or
# sibling on the same launcher. RN_STATION (x11-runtime.sh passes
# $SH_STATION; default nokia9300) names everything the station owns: netns
# rn-<st>, veth <st>rn0 (guest end <st>rn0g, cut to 15 chars), chain
# <ST>RN-IN, MAC RN_<ST>_MAC in local.env. The address comes from RN_GUEST_IP
# (the fixture's NOKIA_RN_IP); only nokia9300 has a default (10.99.0.43), so
# another station can never come up on nokia9300's address by omission.
#
# The amigaos35 shape (streamhost/stations/amigaos35/rn-netns.sh), for the same
# reason: EKA2L1 has no NIC to put on a tap. Its ESock is HLE — the Symbian
# socket server is answered by the emulator with the HOST process's own
# sockets, and RHostResolver::GetByName is the host's getaddrinfo() (after the
# config.yml `hosts:` map, which the station leaves empty). Bare, that would put
# the 9300's traffic on labhost's stack. So the cage is a NETWORK NAMESPACE:
# x11-runtime.sh starts the station's systemd-nspawn container with
# --network-namespace-path=/run/netns/$NS (instead of --private-network), and the
# netns' ONLY interface is the guest end of a veth pair whose host end is a port
# on vmbr-rn. Every socket Opera opens — and every name it resolves, through the
# container's /etc/resolv.conf, which the launcher binds from
# /etc/netns/$NS/resolv.conf → the gateway's wildcard DNS 10.99.0.2 — happens at
# the station's IP/MAC on the museum bridge.
#
# Containment layers (same three as every bridged station):
#   1. TOPOLOGY  vmbr-rn has bridge-ports none — no uplink, never the LAN's L2.
#   2. ROUTING   the netns has ONLY the 10.99.0.0/24 link route: no default
#                route exists, so no packet to anything off the plane can form.
#                The container also runs without CAP_NET_ADMIN, so nothing
#                inside can add one.
#   3. FILTER    fail-closed INPUT chain below, scoped to the guest IP, above
#                RETRONET-IN — labhost's own 10.99.0.1 listeners stay closed
#                to flows the station starts.
#
# The guest MAC rides the veth guest end and follows the fleet scheme
# (52:54:00:52:4e:<ip-hex>); the real value lives ONLY in gitignored
# registry/local.env as RN_<ST>_MAC — the committed placeholder below is
# scrubbed per AGENTS.md rule 1.
#
# Idempotent; called `up` from x11-runtime.sh on every launch when
# NOKIA_NET=retronet. `down` is for teardown by hand. A rig overrides RN_NS,
# RN_VETH_HOST/GUEST (and so the chain name) — never the address while the
# live station is networked.
#
#   rn-netns.sh up      netns + veth + bridge port + resolv.conf + guard
#   rn-netns.sh down    remove guard + veth + netns
#   rn-netns.sh show    current state
set -u

ST="${RN_STATION:-nokia9300}"
case "$ST" in '' | *[!a-z0-9]*)
  echo "rn-netns: bad RN_STATION '$ST'" >&2
  exit 1
  ;;
esac
ST_UP="$(printf '%s' "$ST" | tr '[:lower:]' '[:upper:]')"
NS="${RN_NS:-rn-$ST}"
IF_H="${RN_VETH_HOST:-${ST}rn0}"
_g="${ST}rn0g"
[ "${#_g}" -le 15 ] || _g="${_g:0:14}g"
IF_G="${RN_VETH_GUEST:-$_g}"
BRIDGE="${RN_BRIDGE:-vmbr-rn}"
_ip_default=""
[ "$ST" = nokia9300 ] && _ip_default=10.99.0.43
GUEST_IP="${RN_GUEST_IP:-$_ip_default}"
[ -n "$GUEST_IP" ] || {
  echo "rn-netns: no RN_GUEST_IP for $ST (set NOKIA_RN_IP in its fixture)" >&2
  exit 1
}
DNS_IP="${RN_DNS_IP:-10.99.0.2}"
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
GUEST_MAC="02:00:00:00:00:2b" # placeholder (committed); real value in local.env
_m="$(sed -n "s/^RN_${ST_UP}_MAC=//p" "$RN_LOCAL_ENV" 2>/dev/null | head -1)"
[ -n "$_m" ] && GUEST_MAC="$_m"

# PER-INTERFACE chain name — the clone-teardown containment lesson
# (streamhost/stations/irix/rn-tapnet.sh header, commit 9e7cc64): the
# production veth keeps the bare registry name, anything else is suffixed.
if [ -n "${RN_IN_CHAIN:-}" ]; then
  IN_CHAIN="$RN_IN_CHAIN"
elif [ "$IF_H" = "${ST}rn0" ]; then
  IN_CHAIN="${ST_UP}RN-IN"
else
  IN_CHAIN="${ST_UP}RN-IN-$IF_H"
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
  # The netns' resolv.conf: `ip netns exec` bind-mounts it for tooling, and
  # x11-runtime.sh binds it read-only over the container's /etc/resolv.conf —
  # what EKA2L1's host-side getaddrinfo() reads.
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
  # The nextstep veth TX-offload lesson, kept although only kernel sockets use
  # this link today: checksum offload off on both ends, so a pcap-class reader
  # (a future capture, a debugging tcpdump replay) never sees unfilled sums.
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
    sed -n '2,48p' "$0" >&2
    exit 2
    ;;
esac
