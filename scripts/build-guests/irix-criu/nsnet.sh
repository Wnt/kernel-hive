#!/usr/bin/env bash
# nsnet.sh — the network shape a CRIU-checkpointable IRIX tile needs: a private
# netns holding the guest tap, joined to the host by a veth pair, carrying the
# same containment as `tapnet.sh` egress mode (guest may dial OUT, nothing may
# dial IN).
#
#   nsnet.sh up      create or RE-APPLY (idempotent; this is the post-restore
#                    hook as well as the first-time setup)
#   nsnet.sh down    tear the namespace and every host rule down
#   nsnet.sh show    print what is currently installed, host side and ns side
#   nsnet.sh rules   re-apply the host rules only
#
# WHY A VETH PAIR AND NOT A ROUTER PROCESS. criu can dump a netns containing a
# veth if it is told `--external veth[$INNER]:$OUTER`, and it DELETES and
# RE-CREATES the pair on restore — a new ifindex every cycle, and the host end
# comes back BARE. That is why `up` must be idempotent and must be re-run after
# every restore; it re-applies host addressing, per-interface forwarding, the
# fail-closed chains and the masquerade in ~90 ms.
#
# slirp4netns and pasta are DEAD ENDS for this — see README.md. Do not re-probe.
#
# Per-rig namespacing (set all of these, uniquely, for concurrent agents):
#   NS    netns name          GTAP  guest-facing tap inside the netns
#   OUT   host end of veth    INN   netns end of veth
#   WAN   host uplink bridge
# The guest /30 (GCIDR/GIP) is baked into the golden and is NOT a free choice.
set -u

NS="${NS:?set NS to a namespaced netns name}"
GTAP="${GTAP:?set GTAP to a namespaced tap name}"
OUT="${OUT:?set OUT to a namespaced veth name}"
INN="${INN:?set INN to a namespaced veth peer name}"
WAN="${WAN:-vmbr0}"
# The golden's baked gateway and guest address. Changing these means re-baking.
GCIDR="${GCIDR:-172.31.20.1/30}"
GNET="${GNET:-172.31.20.0/30}"
# The uplink /30 between the netns and the host. Namespace it too.
UPNET="${UPNET:-172.31.23.0/30}"
OUTIP="${OUTIP:-172.31.23.1/30}"
INNIP="${INNIP:-172.31.23.2/30}"

FWD="NSNET-FWD-$OUT"
NATC="NSNET-NAT-$OUT"
INC="NSNET-IN-$OUT"

nse() { nsenter --net=/run/netns/"$NS" "$@"; }
say() { echo "nsnet: $*"; }

# Every chain is named after $OUT, so two concurrent rigs cannot flush each
# other's rules. A shared chain name is the failure that took a sibling rig's
# taps down while it printed "host-only".
host_rules() {
  local ipt
  sysctl -qw "net.ipv4.conf.$OUT.forwarding=1"
  sysctl -qw "net.ipv4.conf.$OUT.rp_filter=1"
  sysctl -qw "net.ipv6.conf.$OUT.disable_ipv6=1"
  sysctl -qw "net.ipv4.conf.$WAN.forwarding=1"
  for ipt in iptables ip6tables; do
    # -w 15: without the xtables lock a concurrent rig's call wins the race and
    # this one returns success having installed nothing.
    "$ipt" -w 15 -N "$FWD" 2>/dev/null || true
    "$ipt" -w 15 -F "$FWD"
    if [ "$ipt" = iptables ]; then
      # NEW only guest->WAN. The return path is ESTABLISHED,RELATED only.
      "$ipt" -w 15 -A "$FWD" -i "$OUT" -o "$WAN" -s "$UPNET" \
        -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
      "$ipt" -w 15 -A "$FWD" -i "$WAN" -o "$OUT" -d "$UPNET" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    fi
    "$ipt" -w 15 -A "$FWD" -i "$OUT" -j DROP
    "$ipt" -w 15 -A "$FWD" -o "$OUT" -j DROP
    while "$ipt" -w 15 -D FORWARD -j "$FWD" 2>/dev/null; do :; done
    "$ipt" -w 15 -I FORWARD 1 -j "$FWD"
  done
  # The guest may address the host end of the uplink /30 and nothing else here.
  iptables -w 15 -N "$INC" 2>/dev/null || true
  iptables -w 15 -F "$INC"
  iptables -w 15 -A "$INC" -s "$UPNET" -d "${OUTIP%%/*}" -j RETURN
  iptables -w 15 -A "$INC" -j DROP
  while iptables -w 15 -D INPUT -i "$OUT" -j "$INC" 2>/dev/null; do :; done
  iptables -w 15 -I INPUT 1 -i "$OUT" -j "$INC"

  iptables -w 15 -t nat -N "$NATC" 2>/dev/null || true
  iptables -w 15 -t nat -F "$NATC"
  iptables -w 15 -t nat -A "$NATC" -s "$UPNET" -o "$WAN" -j MASQUERADE
  while iptables -w 15 -t nat -D POSTROUTING -j "$NATC" 2>/dev/null; do :; done
  iptables -w 15 -t nat -I POSTROUTING 1 -j "$NATC"
}

host_rules_rm() {
  local ipt
  for ipt in iptables ip6tables; do
    while "$ipt" -w 15 -D FORWARD -j "$FWD" 2>/dev/null; do :; done
    "$ipt" -w 15 -F "$FWD" 2>/dev/null || true
    "$ipt" -w 15 -X "$FWD" 2>/dev/null || true
  done
  while iptables -w 15 -D INPUT -i "$OUT" -j "$INC" 2>/dev/null; do :; done
  iptables -w 15 -F "$INC" 2>/dev/null || true
  iptables -w 15 -X "$INC" 2>/dev/null || true
  while iptables -w 15 -t nat -D POSTROUTING -j "$NATC" 2>/dev/null; do :; done
  iptables -w 15 -t nat -F "$NATC" 2>/dev/null || true
  iptables -w 15 -t nat -X "$NATC" 2>/dev/null || true
  return 0
}

up() {
  ip netns list | grep -qx "$NS" || {
    ip netns add "$NS"
    nse ip link set lo up
  }
  nse ip link show "$GTAP" >/dev/null 2>&1 || nse ip tuntap add dev "$GTAP" mode tap
  nse ip addr replace "$GCIDR" dev "$GTAP"
  nse ip link set "$GTAP" up
  nse sysctl -qw net.ipv4.ip_forward=1
  nse sysctl -qw "net.ipv6.conf.$GTAP.disable_ipv6=1" 2>/dev/null || true
  ip link show "$OUT" >/dev/null 2>&1 || ip link add "$OUT" type veth peer name "$INN" netns "$NS"
  ip addr replace "$OUTIP" dev "$OUT"
  ip link set "$OUT" up
  nse ip addr replace "$INNIP" dev "$INN"
  nse ip link set "$INN" up
  nse ip route replace default via "${OUTIP%%/*}"
  nse iptables -t nat -C POSTROUTING -s "$GNET" -o "$INN" -j MASQUERADE 2>/dev/null ||
    nse iptables -t nat -A POSTROUTING -s "$GNET" -o "$INN" -j MASQUERADE
  host_rules
  say "up: ns=$NS gtap=$GTAP($GCIDR) uplink $OUT<->$INN $UPNET wan=$WAN"
}

down() {
  host_rules_rm
  ip link del "$OUT" 2>/dev/null || true
  ip netns del "$NS" 2>/dev/null || true
  say "down"
  return 0
}

show() {
  echo "--- host"
  ip -br addr show "$OUT" 2>/dev/null || true
  iptables -S "$FWD" 2>/dev/null || true
  iptables -t nat -S "$NATC" 2>/dev/null || true
  iptables -S "$INC" 2>/dev/null || true
  echo "--- ns"
  nse ip -br addr
  nse ip route
  nse iptables -t nat -S POSTROUTING
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  show) show ;;
  rules) host_rules ;;
  *)
    echo "usage: nsnet.sh up|down|show|rules" >&2
    exit 2
    ;;
esac
