#!/bin/bash
# wi-tapnet.sh — the rhapsody station's WALK-IN link: the clone's tap on the
# walk-in bridge vmbr-wi.
#
# Self-contained, per the standing rule against coupling sibling stations
# (AGENTS.md rule 3): this is rhapsody's OWN copy of the guarded-tap pattern. It
# is modelled on streamhost/stations/win311/rn-tapnet.sh and is the walk-in
# SIBLING of this station's streamhost/stations/rhapsody/rn-tapnet.sh — not a
# flag on it. The live station keeps rhaprn0 on vmbr-rn; nothing here touches it.
#
# Contract: docs/lab/walkin/CONTRACT-LEDGER.md §5.1 (tap name wi-<os>-<n>), §5.4
# (one clone per station) and §6 (bridge vmbr-wi, gateway CT 952 at 10.99.0.2,
# no DHCP, per-tap port isolation, fail-closed WI<STATION>-IN chain).
#
# THE PLANE DOES NOT RENUMBER. vmbr-wi carries 10.99.0.0/24 with its gateway at
# 10.99.0.2 — deliberately the SAME numbering as the retronet, on a different L2
# with no route between them (ledger §6). That is what makes rhapsody work here
# unchanged: Rhapsody 5.1 DR2 ships NO DHCP client at all (only the BOOTP-era
# bpwhoami), so its address is STATIC in /etc/iftab and in the checkpoint's
# vmstate — 10.99.0.22/24, DNS 10.99.0.2, ROUTER=-NO- so no default route at
# all. A clone therefore arrives believing exactly what it believed when it was
# captured, and on this plane it is RIGHT. No walk-in golden, no second lineage,
# no recapture (AGENTS.md rule 6). WI_TAP_GUEST_IP defaults to that address
# because that is the address the guest genuinely uses.
#
# A POOL OF IDENTICAL MACHINES (§5.4): loadvm restores the NIC MAC from saved
# device state and mac= cannot override it, so every rhapsody clone shares one
# MAC and one baked address — which is why clones never share a bridge. The
# broker builds each clone its own L2 cell (`wibr<slot>`, wi-clonecell, §6) and
# passes it as WI_TAP_BRIDGE; the cell's NAT joins it to vmbr-wi as a unique
# peer, and this script only ever sees one clone per bridge.
#
# WHAT A WALK-IN CLONE IS ALLOWED TO SEE: the corpus web on the walk-in gateway,
# and nothing else — not the fleet, not labhost, not another clone. Four
# independent locks, no single point of failure:
#
#   1. TOPOLOGY. vmbr-wi has `bridge-ports none` and no uplink, and is a
#      DIFFERENT bridge from vmbr-rn. A clone is never on the retronet's L2 nor
#      on the LAN's. The identical numbering on the two planes is cosmetic: they
#      share no segment and no route, so a clone dialling 10.99.0.2 reaches the
#      walk-in gateway and can never reach the retronet's.
#   2. NO TRANSIT. The walk-in gateway CT 952 is SINGLE-HOMED on vmbr-wi and has
#      no route to vmbr-rn, labhost or the internet — there is nothing for it to
#      forward. The live retronet gateway CT 951 is not modified at all.
#   3. PORT ISOLATION. `bridge link set dev <tap> isolated on` below. Isolated
#      ports may only talk to non-isolated ports, so clone->clone is dropped by
#      the kernel bridge itself; the gateway's veth is the only un-isolated port.
#      No rule to get wrong, and it is READ BACK in verify_rules().
#   4. FILTER. The fail-closed WIRHAPSODY-IN chain below. labhost holds NO
#      address on vmbr-wi (§6), so the host is not even meant to be reachable on
#      this segment — this lock is the belt to that braces: should an address
#      ever appear on the bridge, the clone may still talk to labhost ONLY as
#      the ESTABLISHED reply side of a labhost-initiated flow, and every NEW
#      flow it starts toward labhost is DROPPED.
#
# Nothing else rides this netdev: rhapsody's `labctl exec` is a root getty on
# the COM1 unix-socket serial chardev and its pointer is PS/2 through the
# daemon's abs->rel bridge, so the tap carries only the guest's own TCP/IP.
#
# Idempotent, and meant to be called `up` on EVERY clone launch, so a relaunch
# or a host reboot can never leave a clone on the bridge without containment.
# Unlike the retronet tap this one is EPHEMERAL and per-clone: `down` runs at
# clone teardown and deletes it (registry/walkin/rhapsody.json discardOnKill).
#
#   WI_TAP_IF=wi-rhapsody-1 wi-tapnet.sh up     create + enslave + isolate + guard
#   WI_TAP_IF=wi-rhapsody-1 wi-tapnet.sh down   remove guard + unslave + delete
#   WI_TAP_IF=wi-rhapsody-1 wi-tapnet.sh show   current state
set -u

# Per-clone tap, ledger §5.1 form wi-<os>-<n> (<=15 chars, kernel limit).
IF="${WI_TAP_IF:-wi-rhapsody-1}"
BRIDGE="${WI_TAP_BRIDGE:-vmbr-wi}"
# The address the clone actually sources from: the static address baked into
# the golden, which the walk-in plane's numbering deliberately keeps valid.
GUEST_IP="${WI_TAP_GUEST_IP:-10.99.0.22}"
IN_CHAIN="WIRHAPSODY-IN"
# Seconds to wait for the xtables lock. Not optional: a lost race brings the tap
# up with NO fail-closed rules while every message still says "up", which is why
# install_rules is read back by verify_rules.
IPT_WAIT="${WI_TAP_IPT_WAIT:-15}"

msg() { echo "wi-tapnet: $*"; }
die() {
  echo "wi-tapnet: $*" >&2
  exit 1
}

# Fail-closed filter: the clone may talk to labhost ONLY as the reply side of a
# flow labhost opened. Every NEW flow it starts toward labhost is dropped.
# Rebuilt each call.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  # replies to a labhost-initiated probe (labhost dialled the clone first).
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # everything else the clone initiates toward labhost — the gallery, sshd, any
  # 0.0.0.0 listener reachable via a bridge address — is refused.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # Hook the clone's source address into INPUT at position 1, so this scoped
  # DROP sits above anything a broader chain may RETURN on. Re-inserted on every
  # launch, which keeps it above boot-time chains.
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -I INPUT 1 -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN"
}

# Kernel-enforced private-VLAN isolation for this port (ledger §6, lock 3).
install_isolation() {
  bridge link set dev "$IF" isolated on || die "could not isolate port $IF on $BRIDGE"
}

# Read BOTH the isolation and the filter back out of the kernel: neither can be
# trusted to have worked just because the command ran (lock contention, a
# ruleset reload underneath, an iproute2 that silently ignored the flag).
verify_rules() {
  local s
  bridge -d link show dev "$IF" 2>/dev/null | grep -q "isolated on" || return 1
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

# The bridge is per-clone: the broker builds a cell (`wibr<slot>`,
# wi-clonecell) and the tap joins THAT, so identical restored MACs never share
# an FDB (ledger §6). `vmbr-wi` stays accepted for the plane's own tooling; any
# other name — above all vmbr-rn — is refused before a link is touched.
assert_bridge() {
  case "$BRIDGE" in
    vmbr-wi) : ;;
    wibr1[5-9][0-9] | wibr200) : ;;
    *) die "refusing bridge '$BRIDGE': a walk-in tap joins its clone's cell (wibr<slot>) or vmbr-wi, nothing else" ;;
  esac
}

do_up() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  assert_bridge
  case "$IF" in
    *[!a-zA-Z0-9_-]* | '') die "invalid interface name: $IF" ;;
  esac
  [ "${#IF}" -le 15 ] || die "interface name longer than 15 chars: $IF"
  # Refuse to touch this station's LIVE retronet tap, whatever the caller asked
  # for: the walk-in plane must never be able to re-home rhaprn0 onto vmbr-wi.
  [ "$IF" != "rhaprn0" ] || die "refusing: rhaprn0 is the LIVE retronet tap, not a walk-in clone tap"
  [ "$BRIDGE" != "vmbr-rn" ] || die "refusing: vmbr-rn is the retronet; walk-in clones do not go there"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE is absent (the walk-in network plane provisions it)"
  if ! ip link show "$IF" >/dev/null 2>&1; then
    ip tuntap add dev "$IF" mode tap || die "could not create tap $IF"
    msg "created tap $IF"
  fi
  # Enslave to the walk-in bridge. Idempotent: `master` is a no-op if already
  # set to $BRIDGE, and re-homes it if it drifted.
  local cur
  cur="$(cat "/sys/class/net/$IF/master/ifindex" 2>/dev/null || echo '')"
  if [ "$(cat "/sys/class/net/$BRIDGE/ifindex" 2>/dev/null || echo x)" != "$cur" ]; then
    ip link set dev "$IF" master "$BRIDGE" || die "could not enslave $IF to $BRIDGE"
  fi
  # No L3 address on the tap: it is a pure bridge port, and the walk-in gateway
  # lives in CT 952, not on labhost — which holds no address on vmbr-wi at all.
  # IPv6 off on the port for good measure.
  sysctl -qw "net.ipv6.conf.$IF.disable_ipv6=1" 2>/dev/null || true
  install_isolation
  ip link set dev "$IF" up
  install_rules
  if ! verify_rules; then
    install_isolation # one retry: the usual cause is a lost xtables race
    install_rules
    verify_rules || die "clone containment for $IF did not verify — refusing to report up"
  fi
  msg "up: $IF isolated on $BRIDGE; clone $GUEST_IP contained (no clone<->clone, NEW->labhost dropped)"
}

do_down() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  [ "$IF" != "rhaprn0" ] || die "refusing: rhaprn0 is the LIVE retronet tap"
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
  bridge -d link show dev "$IF" 2>/dev/null | tr ' ' '\n' | grep -A1 -x isolated | tr '\n' ' ' || true
  echo
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
