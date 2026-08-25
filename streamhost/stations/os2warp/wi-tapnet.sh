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
# WHAT IS DIFFERENT FROM rn-tapnet.sh, and what deliberately is NOT:
#
#   rn-tapnet.sh                        wi-tapnet.sh
#   ------------------------------------------------------------------------
#   one persistent tap, os2rn0          one EPHEMERAL tap per clone, wi-os2warp-<n>
#   bridge vmbr-rn (the retronet)       bridge vmbr-wi (the walk-in plane)
#   gateway CT 951, five ICQ stations   gateway CT 952, single-homed, corpus only
#   ports may talk to each other        `bridge link set isolated on` — no clone->clone
#   `down` leaves the tap in place      `down` DELETES the tap; clones are throwaway
#   guest holds 10.99.0.19              SAME — see "one numbering" below
#   chain scoped by that source IP      SAME
#
# ONE NUMBERING, TWO L2 DOMAINS. The walk-in plane deliberately reuses the
# retronet's numbering — 10.99.0.0/24, gateway 10.99.0.2 — on a different bridge
# with no route between them (docs/lab/walkin/CONTRACT-LEDGER.md §6). A clone is
# restored with `-loadvm golden`, so its IBM TCP/IP stack comes up holding
# exactly the address and lease it was captured with on vmbr-rn; on this plane
# that belief is simply CORRECT, so there is no DHCP here at all and no walk-in
# golden to capture. It also means the guard chain can be scoped by a STATIC
# source IP, the same way rn-tapnet.sh scopes OS2RN-IN — the two rules differ
# only in `-i`, and never collide.
#
# CONTAINMENT, in layers, none of which is load-bearing on its own
# (docs/lab/WALKIN-BRIEF.md §6.1, docs/lab/walkin/CONTRACT-LEDGER.md §6):
#
#   1. TOPOLOGY. vmbr-wi has `bridge-ports none`, no uplink, and NO ADDRESS ON
#      LABHOST — the host is not reachable on this segment at all. CT 952 is
#      single-homed with nothing to forward. A walk-in clone therefore has no
#      path to the real retronet, the LAN or the internet: that is a topology,
#      not a rule that could be mis-ordered.
#   2. PORT ISOLATION. `bridge link set dev <tap> isolated on`, read back below.
#      An isolated port cannot reach another isolated port, so no walk-in clone
#      can see another walk-in clone; the gateway port stays un-isolated, which
#      is the corpus web the plane exists to serve.
#   3. FILTER. This station's own fail-closed INPUT chain (below) lets the guest
#      reach labhost ONLY as the ESTABLISHED reply side of a labhost-initiated
#      connection; every NEW flow it starts toward labhost is DROPPED. Layer 1
#      already means there is no labhost address to dial, so this layer is
#      defence in depth — it is what stands between a stranger's guest and every
#      0.0.0.0 listener on the box the day somebody puts an address on vmbr-wi
#      for a debugging session and forgets to take it off. Port isolation does
#      not close that: the bridge master is not a port.
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
# ONE CLONE, and therefore one tap, at a time: `loadvm` restores pcnet's MAC from
# saved device state, so two clones of this station would be one host as far as
# the bridge is concerned. Ledger §5.4 settles that by fixing poolSize at 1, so
# wi-os2warp-<n> is a naming convention, not a concurrency plan.
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
# The address the golden was captured holding, and therefore the address the
# restored clone holds on this plane. Static: there is no DHCP on vmbr-wi.
GUEST_IP="${WI_TAP_GUEST_IP:-10.99.0.19}"
IN_CHAIN="WIOS2WARP-IN"
# Seconds to wait for the xtables lock (see irix/tapnet.sh for why this is not
# optional): a lost race brings the tap up with NO fail-closed rules while every
# message still says "up", which is why install_rules is read back by verify_rules.
IPT_WAIT="${WI_TAP_IPT_WAIT:-15}"

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

# Fail-closed filter, scoped to this station's clone by source IP. The clone may
# talk to labhost ONLY as the reply side of a connection labhost opened; every
# NEW flow it starts toward labhost is dropped. Rebuilt each call. The live
# station's OS2RN-IN rule carries the same -s and differs only in -i, so the two
# never collide.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  # replies to a labhost-initiated probe (labhost dialled the clone first).
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # everything else the clone initiates toward labhost is refused.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # Hook it into INPUT at 1, so a later, broader ACCEPT for the walk-in bridge
  # cannot get in front of the scoped DROP. Re-inserted on every launch.
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

# Kernel-enforced private VLAN. Read back too: `bridge link set` is silent on a
# kernel that does not support the flag, and a silently un-isolated port would
# put two strangers' clones on the same L2.
verify_isolated() {
  bridge -d link show dev "$IF" 2>/dev/null | grep -q "isolated on"
}

remove_rules() {
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN" 2>/dev/null; do :; done
  # The chain is per-STATION, not per-clone: only flush and drop it once the
  # last clone's INPUT hook is gone, or tearing down one clone would uncover
  # another. iptables -X refuses a chain that is still referenced, so the
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
  # No L3 address on the tap: it is a pure bridge port, and the clone's only L3
  # peer on this plane is the gateway CT 952.
  sysctl -qw "net.ipv6.conf.$IF.disable_ipv6=1" 2>/dev/null || true
  ip link set dev "$IF" up
  install_rules
  if ! verify_rules; then
    install_rules # one retry: the usual cause is a lost xtables race, not a bad rule
    verify_rules || die "guest containment rules for $IF did not verify — refusing to report up"
  fi
  msg "up: $IF isolated on $BRIDGE; clone $GUEST_IP contained (replies only toward labhost; NEW->labhost dropped)"
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
