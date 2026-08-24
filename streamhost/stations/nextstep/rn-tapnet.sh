#!/bin/bash
# rn-tapnet.sh — the nextstep station's link onto the retronet bridge vmbr-rn.
#
# Sibling of streamhost/stations/irix/rn-tapnet.sh, and the FIRST of the family
# to be a VETH PAIR rather than a tap. Same containment, different plumbing:
#
#   irix / chokanji / rhapsody   a persistent TAP enslaved to vmbr-rn; the
#                                emulator OPENS the tap from the host netns.
#   nextstep (this file)         a private NETNS holding the emulator, joined to
#                                vmbr-rn by a VETH PAIR whose OUTER end is the
#                                bridge port. Previous binds libpcap to the
#                                INNER end.
#
# WHY A VETH AND NOT A TAP. This station is host-native Previous, and it must be
# CRIU-checkpointable. criu can dump a netns containing a veth if it is told
# `--external veth[$INN]:$OUT`, and it deletes and re-creates the pair on
# restore — a new ifindex every cycle, and the host end comes back BARE. It
# CANNOT dump a tap whose fd lives outside the dump set
# (`criu/tun.c: No fd info for non persistent tun device`), which is exactly the
# shape every other station on this bridge uses. slirp4netns and pasta are
# documented dead ends for the same problem — see
# scripts/build-guests/irix/irix-criu/README.md; do not re-probe them.
#
# So `up` is idempotent BY REQUIREMENT, not merely as a courtesy: it is the
# post-restore hook as well as the first-time setup, and it re-applies the
# enslavement, the port settings and the fail-closed chain in one pass.
#
# Containment is layered exactly as on irix, and depends on no single thing:
#
#   1. TOPOLOGY. $OUT is enslaved ONLY to vmbr-rn, which has `bridge-ports none`
#      and no uplink. The guest is never on the LAN's L2. The INNER end lives in
#      a netns with no other interface but `lo`, so even a compromised emulator
#      process has no second path out.
#   2. ROUTING. The guest has NO default route — NeXTSTEP 3.3's /etc/hostconfig
#      carries `ROUTER=-NO-`, so its stack cannot form a packet to anything off
#      10.99.0.0/24. labhost's `retronet-fw` FORWARD chain drops any vmbr-rn
#      traffic trying to route THROUGH the box regardless.
#   3. FILTER. This station's own fail-closed INPUT chain (below), scoped to the
#      guest's source IP, drops every NEW connection the guest starts toward
#      labhost. Without it the guest could open labhost's 0.0.0.0 listeners by
#      dialling the bridge address 10.99.0.1, which retronet-fw deliberately
#      leaves reachable (`RETRONET-IN` returns -d 10.99.0.1), and
#      no-default-route does not close that because 10.99.0.1 is ON the guest's
#      own subnet.
#
# What this link DOES expose, stated plainly: the other guests on vmbr-rn can
# address 10.99.0.25, and what they would find is NeXTSTEP 3.3's telnetd with a
# passwordless `me` and a passwordless `root` behind it. That is the same trade
# irix makes with its telnetd and its two root Apaches; the plane is the invited
# museum's, not the LAN's. labhost dialling IN is what the bring-up exec channel
# uses and the ESTABLISHED,RELATED RETURN rule keeps working; it grants the
# guest nothing it can start.
#
# Intra-bridge traffic (guest -> CT 10.99.0.2 for DNS + the :80 corpus origin) is
# pure L2 with bridge-nf-call-iptables=0, so it never touches these chains and is
# always allowed — that is the retronet reaching the retronet, which is the point.
#
#   rn-tapnet.sh up      create netns + veth + enslave + install/verify guard
#   rn-tapnet.sh down    remove guard + delete the pair and the netns
#   rn-tapnet.sh show    current state, host side and ns side
#   rn-tapnet.sh rules   re-apply the host guard only
#
# Per-rig namespacing (set ALL of these, uniquely, for a bring-up rig so two
# concurrent agents cannot flush each other's rules):
#   RN_NS   netns name        RN_VETH_OUT  host end      RN_VETH_INN  netns end
#   RN_TAP_GUEST_IP           the guest's address        RN_IN_CHAIN  guard chain
set -u

NS="${RN_NS:-nextstep-rn}"
OUT="${RN_VETH_OUT:-nextrn0}"
INN="${RN_VETH_INN:-nextrn1}"
BRIDGE="${RN_TAP_BRIDGE:-vmbr-rn}"
# The guest's statically configured address on vmbr-rn, reserved (but never
# leased) in RETRONET_DHCP_RESERVATIONS so nothing else can take it. The guard
# chain is scoped to it, so the filter follows the guest, never the whole bridge.
GUEST_IP="${RN_TAP_GUEST_IP:-10.99.0.25}"
# PER-INTERFACE chain name, and this is not tidiness — it is the containment
# failure irix's tapnet.sh paid for on 2026-08-24 and its rn-tapnet.sh re-met the
# same day. A bring-up rig brings up a SECOND link for the SAME guest address
# (that is the point: it is this station, on a rig), and because install_rules
# FLUSHES its chain and remove_rules DELETES it, tearing the rig's link down
# removed the LIVE station's INPUT filter while every message still said
# "down: ok". One chain set per link.
#
# The production interface keeps the bare name so the registry's
# `retronet.guard` value and every doc stay true; anything else gets a suffix.
# iptables' chain-name limit is 28 characters.
if [ -n "${RN_IN_CHAIN:-}" ]; then
  IN_CHAIN="$RN_IN_CHAIN"
elif [ "$OUT" = nextrn0 ]; then
  IN_CHAIN="NEXTSTEPRN-IN"
else
  IN_CHAIN="NEXTSTEPRN-IN-$OUT"
fi
# Seconds to wait for the xtables lock: a lost race installs NOTHING while every
# message still says "up", which is why install_rules is read back by verify_rules.
IPT_WAIT="${RN_TAP_IPT_WAIT:-15}"

msg() { echo "rn-tapnet: $*"; }
die() {
  echo "rn-tapnet: $*" >&2
  exit 1
}
nse() { nsenter --net=/run/netns/"$NS" "$@"; }

# Fail-closed filter: every NEW flow the guest starts toward labhost is dropped;
# only the reply side of a labhost-initiated flow returns. Rebuilt from empty on
# each call, and named after the station so concurrent rigs cannot collide.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  # replies to something labhost dialled (the bring-up telnet exec channel).
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # everything else the guest initiates toward labhost — gallery :8443, ssh :22,
  # any 0.0.0.0 listener reachable via the bridge address — is refused.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # Hook the guest's source IP into INPUT ABOVE retronet-fw's RETRONET-IN so the
  # scoped DROP wins over its blanket `-d 10.99.0.1 -j RETURN`.
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

check_name() {
  case "$1" in
    *[!a-zA-Z0-9_-]* | '') die "invalid interface name: $1" ;;
  esac
  # IFNAMSIZ is 16 including the NUL and the kernel TRUNCATES silently — an
  # over-long name is a collision waiting to happen, not a cosmetic problem.
  [ "${#1}" -le 15 ] || die "interface name longer than 15 chars: $1"
}

do_up() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  check_name "$OUT"
  check_name "$INN"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE is absent (the gateway provisioner makes it)"

  ip netns list | awk '{print $1}' | grep -qx "$NS" || {
    ip netns add "$NS" || die "could not create netns $NS"
    nse ip link set lo up
    msg "created netns $NS"
  }
  # The pair. After a criu restore it is already there with a new ifindex, so
  # every step below has to be a no-op in that case rather than an error.
  if ! ip link show "$OUT" >/dev/null 2>&1; then
    ip link add "$OUT" type veth peer name "$INN" netns "$NS" || die "could not create veth $OUT<->$INN"
    msg "created veth $OUT <-> $INN (netns $NS)"
  fi
  nse ip link show "$INN" >/dev/null 2>&1 || die "$INN is not in netns $NS — tear down with 'down' and retry"

  # Enslave the OUTER end to the retronet bridge. Idempotent: `master` is a no-op
  # if already set to $BRIDGE, and re-homes it if it drifted.
  local cur
  cur="$(cat "/sys/class/net/$OUT/master/ifindex" 2>/dev/null || echo '')"
  if [ "$(cat "/sys/class/net/$BRIDGE/ifindex" 2>/dev/null || echo x)" != "$cur" ]; then
    ip link set dev "$OUT" master "$BRIDGE" || die "could not enslave $OUT to $BRIDGE"
  fi
  # No L3 address on either end: both are pure L2. The GUEST owns 10.99.0.25;
  # giving the inner end an address would put a second stack on the guest's IP.
  sysctl -qw "net.ipv6.conf.$OUT.disable_ipv6=1" 2>/dev/null || true
  ip link set dev "$OUT" up
  nse sysctl -qw "net.ipv6.conf.$INN.disable_ipv6=1" 2>/dev/null || true
  # promisc: libpcap asks for it too, but setting it here means the link is
  # already correct before Previous opens it, and stays correct if it restarts.
  nse ip link set dev "$INN" promisc on up
  # CHECKSUM OFFLOAD OFF, ON BOTH ENDS — load-bearing, and the single most
  # expensive thing found on this station.
  #
  # Linux hands a locally-generated TCP segment to a veth with the checksum
  # field UNFILLED (CHECKSUM_PARTIAL): a real NIC would compute it, and a peer
  # in the same kernel understands the flag and never looks. libpcap does not.
  # Previous reads the raw frame off $INN and gives it to NeXTSTEP, whose 1994
  # TCP validates the checksum, finds garbage, and SILENTLY DROPS it — no RST,
  # no ICMP, nothing on the wire but retransmitted SYNs.
  #
  # The symptom is a station that pings perfectly, answers an nmap SYN scan with
  # eight open ports (nmap reads replies through libpcap, below the host stack),
  # and refuses every ordinary connection from labhost. It reads exactly like a
  # firewall bug or a dead inetd, and it is neither. ICMP is unaffected because
  # the kernel checksums ICMP in software, which is why ping is the one probe
  # that lies here. GSO/TSO are off for the same reason: an over-MTU segment the
  # NIC would have split arrives as one oversized frame the guest cannot parse.
  #
  # Only the HOST->guest direction is broken (the guest checksums its own
  # traffic properly), so guest->gateway works with or without this and cannot
  # be used to detect the fault.
  ethtool -K "$OUT" tx off gso off tso off gro off >/dev/null 2>&1 || true
  nse ethtool -K "$INN" tx off gso off tso off gro off >/dev/null 2>&1 || true

  install_rules
  if ! verify_rules; then
    install_rules # one retry: the usual cause is a lost xtables race, not a bad rule
    verify_rules || die "guest containment rules for $OUT did not verify — refusing to report up"
  fi
  msg "up: $OUT enslaved to $BRIDGE, $INN in netns $NS; guest $GUEST_IP contained (NEW->labhost dropped)"
}

do_down() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  remove_rules
  # Deleting either end deletes the pair; deleting the netns takes the inner end
  # with it, so order only matters for the message.
  ip link show "$OUT" >/dev/null 2>&1 && ip link del dev "$OUT"
  ip netns list | awk '{print $1}' | grep -qx "$NS" && ip netns del "$NS"
  msg "down: $OUT, $INN and netns $NS removed"
  return 0
}

do_show() {
  echo "--- host"
  ip -br addr show "$OUT" 2>/dev/null || echo "$OUT: absent"
  echo "master=$(basename "$(readlink "/sys/class/net/$OUT/master" 2>/dev/null || echo none)")"
  echo "carrier=$(cat "/sys/class/net/$OUT/carrier" 2>/dev/null || echo '?')"
  iptables -w "$IPT_WAIT" -S "$IN_CHAIN" 2>/dev/null || echo "(no $IN_CHAIN)"
  iptables -w "$IPT_WAIT" -S INPUT | grep -- "$IN_CHAIN" || echo "(INPUT not hooked)"
  echo "--- netns $NS"
  if ip netns list | awk '{print $1}' | grep -qx "$NS"; then
    nse ip -br addr
    nse ip -d link show "$INN" | sed -n '1,2p'
  else
    echo "(absent)"
  fi
}

case "${1:-}" in
  up) do_up ;;
  down) do_down ;;
  show) do_show ;;
  rules) install_rules && verify_rules && echo "rn-tapnet: rules re-applied and verified" ;;
  *)
    sed -n '2,60p' "$0" >&2
    exit 2
    ;;
esac
