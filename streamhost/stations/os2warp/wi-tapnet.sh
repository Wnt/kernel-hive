#!/bin/bash
# wi-tapnet.sh — the os2warp WALK-IN clone's link onto the walk-in bridge vmbr-wi.
#
# Self-contained, per the standing rule against coupling sibling stations: this
# is os2warp's OWN copy of the guarded-tap pattern, modelled on
# streamhost/stations/win311/rn-tapnet.sh and on this station's own
# rn-tapnet.sh. It is a SIBLING of rn-tapnet.sh, not a mode of it — the live
# station keeps its persistent os2rn0 tap on vmbr-rn and this script must never
# touch it (see the hard refusal in do_up).
#
# WHAT IS DIFFERENT FROM rn-tapnet.sh, and why:
#
#   rn-tapnet.sh                        wi-tapnet.sh
#   ------------------------------------------------------------------------
#   one persistent tap, os2rn0          one EPHEMERAL tap per clone, wi-os2warp-<n>
#   bridge vmbr-rn (the retronet)       bridge vmbr-wi (the walk-in plane)
#   guest holds a reserved 10.99.0.19   guest DHCPs from 10.98.0.100-199, short lease
#   chain scoped by source IP           chain scoped by source MAC (the address is
#                                       dynamic, so an IP scope cannot follow it)
#   ports may talk to each other        `bridge link set isolated on` — no clone->clone
#   `down` leaves the tap in place      `down` DELETES the tap; clones are throwaway
#
# CONTAINMENT, in layers, none of which is load-bearing on its own
# (docs/lab/WALKIN-BRIEF.md §6.1, docs/lab/walkin/CONTRACT-LEDGER.md §6):
#
#   1. TOPOLOGY. vmbr-wi is a separate bridge with `bridge-ports none` and no
#      uplink, and the gateway CT does not forward between its retronet leg and
#      its walk-in leg (ip_forward=0 plus an explicit nft FORWARD drop). A
#      walk-in clone therefore has no path to 10.99.0.0/24 or to the LAN at all
#      — that is a topology, not a rule that could be mis-ordered.
#   2. PORT ISOLATION. `bridge link set dev <tap> isolated on`, read back below.
#      An isolated port cannot reach another isolated port, so no walk-in clone
#      can see another walk-in clone. It CAN still reach the bridge's own L3
#      stack and the un-isolated gateway port — which is exactly the corpus web
#      the plane exists to serve, and exactly why layer 3 is still needed.
#   3. FILTER. This station's own fail-closed INPUT chain (below) lets the guest
#      reach labhost ONLY as the ESTABLISHED reply side of a labhost-initiated
#      connection. Every NEW flow the clone starts toward labhost — the gallery,
#      sshd, any 0.0.0.0 listener reachable via the bridge address — is DROPPED.
#      Port isolation does not close this: the bridge master is not a port.
#
# The guest is IBM OS/2 Warp 4.52 (MCP2) running MPTS/NDIS + IBM TCP/IP 4.3, and
# a walk-in clone of it is anonymous code on a public plane, so the chain is
# rebuilt and READ BACK on every launch rather than trusted to have survived.
#
# os2warp's pointer path does NOT run over this netdev: the warpd agent lives on
# a COM1 unix-socket serial chardev. Nothing but the guest's own TCP/IP rides
# this tap, which is why the walk-in netdev override is device-set-safe — the
# -device pcnet is UNCHANGED and only the backend moves (OPERATING-RULES rule 6).
#
# WHY THE CHAIN IS SCOPED BY MAC, and the caveat that comes with it: a walk-in
# clone is restored with `-loadvm golden`, and pcnet's MAC lives in the restored
# CSR block, so every clone of this station presents the SAME baked MAC whatever
# `mac=` says on the command line. That makes the MAC a reliable per-STATION
# scope (which is what the WI<STATION>-IN chain wants) but it is NOT unique per
# clone — see the PATHFINDER NOTES at the foot of this file, which the pool
# owner has to read before poolSize goes above 1.
#
#   WI_TAP_IF=wi-os2warp-1 wi-tapnet.sh up     create + enslave + isolate + guard
#   WI_TAP_IF=wi-os2warp-1 wi-tapnet.sh down   remove guard + delete the tap
#   WI_TAP_IF=wi-os2warp-1 wi-tapnet.sh show   current state
set -u

# No default: a walk-in tap name is per-clone and is the broker's to choose. An
# override that falls back to a live name is the clone-guard incident in a
# different costume, so an unset WI_TAP_IF is a hard error, never os2rn0.
IF="${WI_TAP_IF:-}"
BRIDGE="${WI_TAP_BRIDGE:-vmbr-wi}"
IN_CHAIN="WIOS2WARP-IN"
# Seconds to wait for the xtables lock (see irix/tapnet.sh for why this is not
# optional): a lost race brings the tap up with NO fail-closed rules while every
# message still says "up", which is why install_rules is read back by verify_rules.
IPT_WAIT="${WI_TAP_IPT_WAIT:-15}"

# The MAC the golden's pcnet CSRs carry, and therefore the source MAC every
# clone of this station puts on the wire. Only the one line is read, never the
# whole (secret-bearing) file — same convention as qemu-streamhost.sh.
WI_LOCAL_ENV="${WI_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
GUEST_MAC="${WI_TAP_GUEST_MAC:-}"
if [ -z "$GUEST_MAC" ]; then
  GUEST_MAC="02:00:00:00:00:13" # placeholder (committed); real value from local.env
  if [ -r "$WI_LOCAL_ENV" ]; then
    _m="$(sed -n 's/^RN_OS2WARP_MAC=//p' "$WI_LOCAL_ENV" | head -1)"
    [ -n "$_m" ] && GUEST_MAC="$_m"
  fi
fi

msg() { echo "wi-tapnet: $*"; }
die() {
  echo "wi-tapnet: $*" >&2
  exit 1
}

# The one name this script may never operate on: the LIVE station's persistent
# retronet tap. Cheap, explicit, and it turns a mis-set WI_TAP_IF into a refusal
# instead of an outage on os2warp.
assert_walkin_if() {
  [ -n "$IF" ] || die "WI_TAP_IF is unset — a walk-in tap name is per-clone and has no default"
  case "$IF" in
    os2rn0) die "refusing to touch the LIVE station tap os2rn0 — this script is the walk-in sibling" ;;
    wi-os2warp-[0-9] | wi-os2warp-[0-9][0-9]) : ;;
    *) die "invalid walk-in tap name: $IF (expected wi-os2warp-<n>, ledger §5.1)" ;;
  esac
  [ "${#IF}" -le 15 ] || die "interface name longer than 15 chars: $IF"
}

# Fail-closed filter, scoped to this station's guests by source MAC. The clone
# may talk to labhost ONLY as the reply side of a connection labhost opened;
# every NEW flow it starts toward labhost is dropped. Rebuilt each call.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  # replies to a labhost-initiated probe (labhost dialled the clone first).
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # everything else the clone initiates toward labhost is refused.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # Hook it into INPUT at 1, so a later, broader ACCEPT for the walk-in bridge
  # cannot get in front of the scoped DROP. Re-inserted on every launch.
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -m mac --mac-source "$GUEST_MAC" -j "$IN_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -I INPUT 1 -i "$BRIDGE" -m mac --mac-source "$GUEST_MAC" -j "$IN_CHAIN"
}

# Read the isolation back out of the kernel: install_rules cannot be trusted to
# have worked just because it ran (lock contention, a ruleset reload underneath).
verify_rules() {
  local s
  s="$(iptables -w "$IPT_WAIT" -S 2>/dev/null)" || return 1
  grep -qx -- "-A INPUT -i $BRIDGE -m mac --mac-source $GUEST_MAC -j $IN_CHAIN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -j DROP" <<<"$s" || return 1
}

# Kernel-enforced private VLAN. Read back too: `bridge link set` is silent on a
# kernel that does not support the flag, and a silently un-isolated port would
# put two strangers' clones on the same L2.
verify_isolated() {
  bridge -d link show dev "$IF" 2>/dev/null | grep -q "isolated on"
}

remove_rules() {
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -m mac --mac-source "$GUEST_MAC" -j "$IN_CHAIN" 2>/dev/null; do :; done
  # The chain is per-STATION, not per-clone: only flush and drop it once the
  # last clone's INPUT hook is gone, or tearing down clone 1 would uncover
  # clone 2. iptables -X refuses a chain that is still referenced, so the
  # `|| true` is the ordinary path, not an ignored failure.
  if ! iptables -w "$IPT_WAIT" -S INPUT 2>/dev/null | grep -q -- "-j $IN_CHAIN"; then
    iptables -w "$IPT_WAIT" -F "$IN_CHAIN" 2>/dev/null || true
    iptables -w "$IPT_WAIT" -X "$IN_CHAIN" 2>/dev/null || true
  fi
}

do_up() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  assert_walkin_if
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE is absent (the walk-in network plane provisions it)"
  # The tap exists before QEMU starts and is opened by
  # -netdev tap,ifname=$IF,script=no,downscript=no. Unlike the retronet tap it
  # is EPHEMERAL: `down` deletes it when the clone is reaped.
  if ! ip link show "$IF" >/dev/null 2>&1; then
    ip tuntap add dev "$IF" mode tap || die "could not create tap $IF"
    msg "created tap $IF"
  fi
  # Enslave to the walk-in bridge. Idempotent: a no-op if already correct, and
  # it re-homes a tap that somehow drifted onto another bridge.
  local cur
  cur="$(cat "/sys/class/net/$IF/master/ifindex" 2>/dev/null || echo '')"
  if [ "$(cat "/sys/class/net/$BRIDGE/ifindex" 2>/dev/null || echo x)" != "$cur" ]; then
    ip link set dev "$IF" master "$BRIDGE" || die "could not enslave $IF to $BRIDGE"
  fi
  # Isolate BEFORE the link comes up, so there is no window in which a clone's
  # first frames reach a neighbouring clone.
  bridge link set dev "$IF" isolated on || die "could not isolate $IF on $BRIDGE"
  verify_isolated || die "port isolation on $IF did not verify — refusing to report up"
  # No L3 address on the tap: it is a pure bridge port, and the walk-in guest's
  # only L3 peers are the gateway CT and the bridge itself.
  sysctl -qw "net.ipv6.conf.$IF.disable_ipv6=1" 2>/dev/null || true
  ip link set dev "$IF" up
  install_rules
  if ! verify_rules; then
    install_rules # one retry: the usual cause is a lost xtables race, not a bad rule
    verify_rules || die "guest containment rules for $IF did not verify — refusing to report up"
  fi
  msg "up: $IF isolated on $BRIDGE; clone contained (replies only toward labhost; NEW->labhost dropped)"
}

do_down() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  assert_walkin_if
  if ip link show "$IF" >/dev/null 2>&1; then
    ip link set dev "$IF" nomaster 2>/dev/null || true
    ip link del dev "$IF"
  fi
  remove_rules
  msg "down: $IF removed"
}

do_show() {
  ip -br addr show "$IF" 2>/dev/null || echo "$IF: absent"
  echo "master=$(basename "$(readlink "/sys/class/net/$IF/master" 2>/dev/null || echo none)")"
  echo "isolated=$(verify_isolated && echo on || echo OFF)"
  echo "disable_ipv6=$(cat "/proc/sys/net/ipv6/conf/$IF/disable_ipv6" 2>/dev/null || echo '?')"
  iptables -w "$IPT_WAIT" -S "$IN_CHAIN" 2>/dev/null || echo "(no $IN_CHAIN)"
  iptables -w "$IPT_WAIT" -S INPUT | grep -- "$IN_CHAIN" || echo "(INPUT not hooked)"
}

case "${1:-}" in
  up) do_up ;;
  down) do_down ;;
  show) do_show ;;
  *)
    sed -n '2,20p' "$0" >&2
    exit 2
    ;;
esac

# PATHFINDER NOTES — two things the pool owner must decide, which are contract
# questions (CONTRACT-LEDGER §5.2 and §6), not this script's to answer:
#
#  1. ONE MAC PER STATION, NOT PER CLONE. `-loadvm golden` restores pcnet's CSRs,
#     which carry the MAC, so `mac=` on the command line cannot make two clones
#     of os2warp distinguishable on the wire, and the device set may not be
#     changed to give them separate NICs. Two clones on one bridge with one MAC
#     flap the FDB and collide on DHCP. Port isolation stops them seeing each
#     other but not the gateway seeing them as one host. The per-tap fix is an
#     ebtables source-MAC rewrite (nat PREROUTING snat on ingress, POSTROUTING
#     dnat on egress) — deliberately NOT implemented here, because it has to be
#     agreed once for all three stations rather than invented three times.
#  2. THE GOLDEN'S BAKED ADDRESS IS A RETRONET ADDRESS. The os2warp golden was
#     recaptured on the retronet, so the restored IBM TCP/IP stack comes up
#     believing it holds 10.99.0.19 with a lease from 10.99.0.2. On the frozen
#     10.98.0.0/24 walk-in plane that address is wrong, and OS/2 will not
#     re-DHCP inside a 20-minute session. Fixing it means either a walk-in
#     golden recaptured on vmbr-wi (checkpoint-guard, and then TWO goldens for
#     one binary and device set) or a coordinator amendment to §6. Containment
#     is unaffected either way: the clone reaches strictly less, not more.
