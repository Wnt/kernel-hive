#!/bin/bash
# rn-tapnet.sh — the w2kalpha station's link onto the retronet bridge vmbr-rn.
#
# es40 has NO tap backend: it captures a host interface with libpcap
# (es40.cfg: `dec21143 { type="pcap"; adapter="w2kalpha-g"; ... }`). So the host
# side of the link is a VETH PAIR, and only the HOST end is a bridge port:
#
#   guest  <- es40 pcap ->  w2kalpha-g  <== veth ==>  w2kalpha-h  -> vmbr-rn (bridge)
#
# es40 opens the GUEST end (w2kalpha-g) with pcap; the HOST end (w2kalpha-h) is
# enslaved to vmbr-rn. Frames the guest sends egress w2kalpha-g -> ingress
# w2kalpha-h -> the bridge forwards them to the gateway CT's veth951i0; frames
# for the guest's MAC leave the bridge on w2kalpha-h -> w2kalpha-g -> es40's
# pcap -> the guest. That is real L2-to-the-gateway (working DHCP + DNS + the
# corpus web on :80), reached by pcap instead of a tap.
#
# BEFORE the retronet swap this NIC was HOST-ONLY: x11-runtime.sh put a
# 172.31.64.1/30 address on w2kalpha-h and the guest held the static 172.31.64.2,
# reachable only from this box (the telnet exec channel rode it). The swap drops
# that host-only /30 and re-homes w2kalpha-h onto vmbr-rn — the guest is now a
# retronet host on DHCP (reserved 10.99.0.17), and the telnet exec channel rides
# the new address. `up` tears down the old /30 so a relaunch converges cleanly.
#
# Containment is layered and does NOT depend on any one thing:
#
#   1. TOPOLOGY. w2kalpha-h is enslaved ONLY to vmbr-rn, a bridge with
#      `bridge-ports none` and NO uplink. The guest is never on the LAN's L2.
#   2. ROUTING. The guest's DHCP lease carries NO option 3 (router), so the
#      guest gets no default route and its own stack cannot form a packet to
#      anything off 10.99.0.0/24. labhost's `retronet-fw` FORWARD chain drops
#      any vmbr-rn traffic that tries to route THROUGH the box regardless.
#   3. FILTER. This station's own fail-closed INPUT chain (below), scoped to the
#      guest's source IP, drops every NEW connection the guest starts toward
#      labhost — the gallery on 10.99.0.1:8443, sshd, anything bound to the
#      bridge address 10.99.0.1 — while letting ESTABLISHED,RELATED replies
#      through. w2kalpha's exec channel is telnet that LABHOST opens to the
#      guest (labhost -> 10.99.0.17:23), so the guest only ever REPLIES toward
#      labhost (ESTABLISHED, allowed); every NEW flow it initiates is dropped.
#      Intra-bridge traffic (guest -> CT 10.99.0.2 for DHCP/DNS/web) is pure L2
#      with bridge-nf-call-iptables=0, so it never touches these chains and is
#      always allowed — the retronet reaching the retronet.
#
# es40 needs w2kalpha-g to EXIST before it starts (pcap opens it at boot), so
# `up` is called from x11-runtime.sh on EVERY launch, before es40 — that is what
# makes the link survive a station relaunch and a host reboot without a separate
# systemd unit. The veth is PERSISTENT: it is not torn down when es40 stops (the
# guard chain then simply contains a guest that is not there). `down` is for
# teardown by hand.
#
#   rn-tapnet.sh up          create veth + enslave w2kalpha-h to vmbr-rn + guard
#   rn-tapnet.sh down        remove guard + unslave + delete the veth
#   rn-tapnet.sh show        current state
set -u

# The pcap (guest) end must match es40.cfg's `adapter =`. The host end is the
# bridge port. Deleting either end removes the pair.
NIC_G="${RN_TAP_IF_G:-w2kalpha-g}" # pcap end es40 captures (es40.cfg adapter=)
NIC_H="${RN_TAP_IF_H:-w2kalpha-h}" # bridge-port end, enslaved to vmbr-rn
BRIDGE="${RN_TAP_BRIDGE:-vmbr-rn}"
# The guest's reserved DHCP address on vmbr-rn. The guard chain is scoped to it,
# so the filter follows the guest, never the whole bridge.
GUEST_IP="${RN_TAP_GUEST_IP:-10.99.0.17}"
IN_CHAIN="W2KALPHARN-IN"
# The pre-swap HOST-ONLY wiring this station used to install, torn down by `up`:
# a /30 address on the host end (never a NAT rule — w2kalpha was host-only, never
# had a WAN path).
OLD_HOSTONLY_ADDR="172.31.64.1/30"
# Seconds to wait for the xtables lock: a lost race would bring the link up with
# NO fail-closed rules while every message still says "up", which is why
# install_rules is read back by verify_rules.
IPT_WAIT="${RN_TAP_IPT_WAIT:-15}"

msg() { echo "rn-tapnet: $*"; }
die() {
  echo "rn-tapnet: $*" >&2
  exit 1
}

# Fail-closed filter: the guest may talk to labhost ONLY as the reply side of a
# connection labhost opened (the telnet exec channel labhost dials on :23). Every
# NEW flow the guest itself initiates toward labhost is dropped. Rebuilt from
# empty each call.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # everything else the guest initiates toward labhost — gallery :8443, ssh :22,
  # any 0.0.0.0 listener reachable via the bridge address — is refused.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # Hook the guest's source IP into INPUT, ABOVE retronet-fw's RETRONET-IN so the
  # scoped DROP wins over its blanket `-d 10.99.0.1 -j RETURN`. Re-inserted at 1
  # on every launch, which keeps it above the boot-time RETRONET-IN.
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

# Tear down the pre-retronet HOST-ONLY path: the /30 address on the host end.
# Idempotent, and safe to run when it was never there. w2kalpha never had a
# MASQUERADE/WAN rule (it was host-only, not NAT'd), so there is none to remove.
remove_old_hostonly() {
  ip addr flush dev "$NIC_H" 2>/dev/null || true
}

do_up() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  for n in "$NIC_G" "$NIC_H"; do
    case "$n" in
      *[!a-zA-Z0-9_-]* | '') die "invalid interface name: $n" ;;
    esac
    [ "${#n}" -le 15 ] || die "interface name longer than 15 chars: $n"
  done
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE is absent (Stream B provisions it)"
  # PERSISTENT veth pair: it exists before es40 starts (pcap opens w2kalpha-g)
  # and survives es40 exiting. Creating one end creates both.
  if ! ip link show "$NIC_G" >/dev/null 2>&1; then
    ip link add "$NIC_H" type veth peer name "$NIC_G" || die "could not create veth $NIC_H/$NIC_G"
    msg "created veth $NIC_H/$NIC_G"
  fi
  # Drop the old host-only address if this host is converging from the pre-swap
  # config; w2kalpha-h is a pure bridge port now, with no L3 of its own.
  remove_old_hostonly
  # veth TX checksum offload leaves locally-originated packets with unfilled
  # checksums, which es40's pcap capture then reads as corrupt frames; disable
  # on BOTH ends (kept from the pre-swap host-only launcher, still required on
  # the bridge).
  ethtool -K "$NIC_H" tx off rx off >/dev/null 2>&1 || true
  ethtool -K "$NIC_G" tx off rx off >/dev/null 2>&1 || true
  # IPv6 off on the bridge-port end for good measure (retronet-fw drops vmbr-rn
  # IPv6 anyway); the guest end is pure pcap, no host stack rides it.
  sysctl -qw "net.ipv6.conf.$NIC_H.disable_ipv6=1" 2>/dev/null || true
  # Enslave the host end to the retronet bridge — the whole point of this swap.
  # Idempotent: `master` is a no-op if already set, and re-homes if it drifted.
  local cur
  cur="$(cat "/sys/class/net/$NIC_H/master/ifindex" 2>/dev/null || echo '')"
  if [ "$(cat "/sys/class/net/$BRIDGE/ifindex" 2>/dev/null || echo x)" != "$cur" ]; then
    ip link set dev "$NIC_H" master "$BRIDGE" || die "could not enslave $NIC_H to $BRIDGE"
  fi
  ip link set "$NIC_H" up
  ip link set "$NIC_G" up
  install_rules
  if ! verify_rules; then
    install_rules # one retry: the usual cause is a lost xtables race, not a bad rule
    verify_rules || die "guest containment rules for $NIC_H did not verify — refusing to report up"
  fi
  msg "up: $NIC_H enslaved to $BRIDGE; es40 captures $NIC_G; guest $GUEST_IP contained (NEW->labhost dropped)"
}

do_down() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  remove_rules
  remove_old_hostonly
  if ip link show "$NIC_H" >/dev/null 2>&1; then
    ip link set dev "$NIC_H" nomaster 2>/dev/null || true
  fi
  # Deleting either end removes the pair.
  if ip link show "$NIC_G" >/dev/null 2>&1; then
    ip link del dev "$NIC_G"
  fi
  msg "down: $NIC_H/$NIC_G removed"
}

do_show() {
  ip -br addr show "$NIC_H" 2>/dev/null || echo "$NIC_H: absent"
  ip -br addr show "$NIC_G" 2>/dev/null || echo "$NIC_G: absent"
  echo "master=$(basename "$(readlink "/sys/class/net/$NIC_H/master" 2>/dev/null || echo none)")"
  echo "disable_ipv6=$(cat "/proc/sys/net/ipv6/conf/$NIC_H/disable_ipv6" 2>/dev/null || echo '?')"
  iptables -w "$IPT_WAIT" -S "$IN_CHAIN" 2>/dev/null || echo "(no $IN_CHAIN)"
  iptables -w "$IPT_WAIT" -S INPUT | grep -- "$IN_CHAIN" || echo "(INPUT not hooked)"
}

case "${1:-}" in
  up) do_up ;;
  down) do_down ;;
  show) do_show ;;
  *)
    sed -n '2,40p' "$0" >&2
    exit 2
    ;;
esac
