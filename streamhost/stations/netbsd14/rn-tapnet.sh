#!/bin/bash
# rn-tapnet.sh — the netbsd14 station's link onto the retronet bridge vmbr-rn.
# Sibling of streamhost/stations/solaris/rn-tapnet.sh; see that file and
# docs/lab/retronet/GATEWAY.md for the three containment layers.
set -u
IF="${RN_TAP_IF:-netbsd14rn0}"
BRIDGE="${RN_TAP_BRIDGE:-vmbr-rn}"
GUEST_IP="${RN_TAP_GUEST_IP:-10.99.0.32}"
IN_CHAIN="NETBSD14RN-IN"
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
  case "$IF" in *[!a-zA-Z0-9_-]* | '') die "invalid interface name: $IF" ;; esac
  [ "${#IF}" -le 15 ] || die "interface name longer than 15 chars: $IF"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE is absent"
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
    install_rules
    verify_rules || die "guest containment rules for $IF did not verify — refusing to report up"
  fi
  msg "up: $IF enslaved to $BRIDGE; guest $GUEST_IP contained"
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
  iptables -w "$IPT_WAIT" -S "$IN_CHAIN" 2>/dev/null || echo "(no $IN_CHAIN)"
  iptables -w "$IPT_WAIT" -S INPUT | grep -- "$IN_CHAIN" || echo "(INPUT not hooked)"
}
case "${1:-}" in
  up) do_up ;; down) do_down ;; show) do_show ;;
  *)
    sed -n '2,6p' "$0" >&2
    exit 2
    ;;
esac
