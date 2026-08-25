#!/bin/bash
# wi-tapnet.sh — a win311 WALK-IN CLONE's link onto the walk-in bridge vmbr-wi.
#
# This is the walk-in sibling of rn-tapnet.sh, NOT a flag on it
# (docs/lab/OPERATING-RULES.md rule 3: fix it in your own stack, never as a
# switch inside someone else's live path). The live station keeps rn-tapnet.sh
# and vmbr-rn untouched; the walk-in clone gets this script and vmbr-wi, and the
# two planes never meet. Contract: docs/lab/walkin/CONTRACT-LEDGER.md §5.1
# (names), §5.4 (one clone per station) and §6 (the plane).
#
# THE PLANE THIS ATTACHES TO, and why it looks like a copy of the retronet:
# vmbr-wi carries the SAME numbering as vmbr-rn — 10.99.0.0/24, gateway CT 952
# at 10.99.0.2 — on a different L2 with no route between them, and labhost holds
# no address on it at all (ledger §6). That is deliberate. `loadvm` restores the
# NIC's saved state, so a clone wakes up holding the DHCP lease its golden was
# captured with (10.99.0.27, DNS 10.99.0.2, no default route) and MS TCP/IP-32
# will not re-DHCP inside a 20-minute session. Rather than fight that, the plane
# presents the numbering the golden already believes, so the clone is simply
# right. There is no DHCP server here and nothing for the guest to renew from.
#
# WHAT IS DIFFERENT FROM THE RETRONET SIBLING:
#
#   1. PER CLONE, AND EPHEMERAL. rn-tapnet.sh owns one PERSISTENT tap for the
#      one live station. A walk-in tap carries the clone ordinal (ledger §5.1:
#      wi-<os>-<n>) and is created by `up` at spawn and deleted by `down` at
#      reap, exactly like the overlay.
#   2. PORT ISOLATION. Every walk-in tap is `isolated on`, so clones of
#      DIFFERENT stations cannot see each other at L2 at all — a kernel-enforced
#      private VLAN, no rules to get wrong. The gateway's port is the only
#      un-isolated port on the bridge, and this script never touches it.
#   3. ONE CLONE, NOT A POOL. poolSize is 1 for win311 and every other walk-in
#      station (ledger §5.4): the ne2k MAC lives in the vmstate, `mac=` cannot
#      override it, and the device set may not be changed to work around it, so
#      two win311 clones on one segment would present one MAC and one address.
#      Measured 2026-08-25 on a stand-in plane: with two clones up, the bridge
#      FDB entry for 52:54:… moved to whichever clone transmitted last. `down`
#      below is still written to survive a sibling, because a containment script
#      that assumes it is alone is one policy change away from unhooking a live
#      guard.
#
# WHAT IS THE SAME, deliberately: the guest is still Windows for Workgroups 3.11
# running Microsoft TCP/IP-32 (MSTCP32) over the RTL8029 NDIS3 driver (PCIND$),
# which is the very card QEMU's ne2k_pci emulates. The clone keeps that device —
# only the netdev BACKEND is re-pointed at this tap. `loadvm golden` matches the
# device set the golden was captured against (rule 6), so a walk-in clone may
# not gain or lose a device, here or anywhere else.
#
# Containment is layered and does not depend on any one thing:
#
#   1. TOPOLOGY. vmbr-wi has `bridge-ports none` and no uplink, and it is a
#      DIFFERENT bridge from vmbr-rn. The retronet is not reachable because
#      there is no path to it, not because a rule says no. Measured on a
#      stand-in plane: the clone ARPs for 10.99.0.2 and gets four unanswered
#      requests — the address it expects is simply not on this L2.
#   2. NO TRANSIT. CT 952 is single-homed with no route to vmbr-rn, labhost or
#      the internet. There is nothing for it to forward.
#   3. NO CLONE-TO-CLONE. `bridge link set dev <tap> isolated on`, verified by
#      reading it back out of the kernel below.
#   4. FILTER. The chain below, scoped to the clone's source address, lets it
#      reach labhost ONLY as the ESTABLISHED reply side of a labhost-initiated
#      connection. Every NEW flow the clone starts toward labhost is DROPPED.
#      labhost has no address on vmbr-wi, so this is defence in depth against an
#      address appearing there later, not the primary lock.
#
# win311's pointer path does NOT run over this netdev: the warpd agent is on a
# COM1 unix-socket serial chardev (guest-agents/win311/agent.c), which the clone
# namespaces by PATH only. Nothing but the guest's own TCP/IP rides this tap.
#
# Intra-bridge traffic (clone -> CT 952 for DNS and HTTP) is pure L2 with
# bridge-nf-call-iptables=0, so it never touches these chains — the walk-in
# reaching the corpus is the point. Proven on a stand-in plane: Netscape 4.08
# fetched the origin over this tap and rendered it to "Document: Done".
#
# The hook is scoped to `-i vmbr-wi`, and rn-tapnet.sh's is scoped to
# `-i vmbr-rn`, so the two chains never see each other's traffic even though
# both are scoped to 10.99.0.27.
#
# Idempotent, and called `up` from the clone's launch on EVERY spawn, so a
# respawn re-asserts both the isolation flag and the guard chain.
#
#   wi-tapnet.sh up          create + enslave to vmbr-wi + isolate + guard
#   wi-tapnet.sh down        remove guard hook + delete the tap (reap)
#   wi-tapnet.sh show        current state
#
# Environment:
#   WI_CLONE          clone identity, walkin-win311-<n> (ledger §5.1). The tap
#                     name is derived from it when WI_TAP_IF is not given.
#   WI_TAP_IF         explicit tap name, overrides the derivation.
#   WI_TAP_BRIDGE     default vmbr-wi.
#   WI_TAP_GUEST_IP   default 10.99.0.27 — the address baked into the golden.
#   WI_TAP_USER       optional uid/name to own the tap, for the per-clone
#                     unprivileged QEMU user. Unset = root-owned, as today.
set -u

BRIDGE="${WI_TAP_BRIDGE:-vmbr-wi}"
# The address the golden was captured holding. The plane does not renumber
# (ledger §6), so this is static and the guard chain follows the clone rather
# than the whole bridge.
GUEST_IP="${WI_TAP_GUEST_IP:-10.99.0.27}"
IN_CHAIN="WIWIN311-IN"
# Seconds to wait for the xtables lock (see irix/tapnet.sh for why this is not
# optional): a lost race brings the tap up with NO fail-closed rules while every
# message still says "up", which is why install_rules is read back by verify_rules.
IPT_WAIT="${WI_TAP_IPT_WAIT:-15}"

msg() { echo "wi-tapnet: $*"; }
die() {
  echo "wi-tapnet: $*" >&2
  exit 1
}

# Tap name: ledger §5.1 form wi-<os>-<n>, derived from the clone identity
# walkin-win311-<n> so the broker does not have to spell it twice.
derive_if() {
  local id="${WI_CLONE:-}"
  case "$id" in
    walkin-win311-*) echo "wi-win311-${id##*-}" ;;
    '') die "set WI_TAP_IF or WI_CLONE (walkin-win311-<n>)" ;;
    *) die "WI_CLONE '$id' is not a win311 walk-in identity (walkin-win311-<n>)" ;;
  esac
}
IF="${WI_TAP_IF:-$(derive_if)}"

# Fail-closed filter: the clone may talk to labhost ONLY as the reply side of a
# connection labhost opened. Every NEW flow the clone starts toward labhost is
# dropped. Rebuilt each call.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  # replies to a labhost-initiated probe (labhost dialled the clone first).
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # everything else the clone initiates toward labhost — gallery :8443, ssh :22,
  # anything that ever binds 0.0.0.0 — is refused.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # Hook the clone's source address on the walk-in bridge into INPUT at 1.
  # Re-inserted on every spawn, which keeps it above anything installed at boot.
  # The `-i $BRIDGE` scope is what keeps this chain and rn-tapnet.sh's
  # WIN311RN-IN apart despite the shared 10.99.0.27.
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

# poolSize is 1 (ledger §5.4), so in practice there is never a sibling. This is
# kept anyway: the chain is per-STATION, and a containment script that assumes
# it is alone is one policy change away from unhooking a live guard. Only the
# last win311 tap to leave removes it.
peers_remain() {
  local d
  for d in /sys/class/net/wi-win311-*; do
    [ -e "$d" ] || continue
    [ "$(basename "$d")" = "$IF" ] && continue
    return 0
  done
  return 1
}

remove_rules() {
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -X "$IN_CHAIN" 2>/dev/null || true
}

# Kernel-enforced private VLAN. `isolated on` ports may talk to un-isolated
# ports (the gateway) and to nothing else — no clone sees another clone's
# frames, including broadcast, which is why this is topology rather than policy.
isolate_port() {
  bridge link set dev "$IF" isolated on || die "could not isolate $IF on $BRIDGE"
}

verify_isolated() {
  bridge -d link show dev "$IF" 2>/dev/null | grep -q "isolated on"
}

do_up() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  case "$IF" in
    wi-win311-[0-9] | wi-win311-[0-9][0-9]) : ;;
    *) die "refusing tap name '$IF': walk-in win311 taps are wi-win311-<n> (ledger §5.1)" ;;
  esac
  [ "${#IF}" -le 15 ] || die "interface name longer than 15 chars: $IF"
  ip link show "$BRIDGE" >/dev/null 2>&1 ||
    die "bridge $BRIDGE is absent (the walk-in network plane owns it) — refusing to fall back to any other bridge"
  # EPHEMERAL tap, unlike the station's persistent retronet tap: it is created
  # with the clone and deleted with it. QEMU attaches with
  # -netdev tap,ifname=$IF,script=no,downscript=no (it opens an existing tap).
  if ! ip link show "$IF" >/dev/null 2>&1; then
    if [ -n "${WI_TAP_USER:-}" ]; then
      ip tuntap add dev "$IF" mode tap user "$WI_TAP_USER" || die "could not create tap $IF"
    else
      ip tuntap add dev "$IF" mode tap || die "could not create tap $IF"
    fi
    msg "created tap $IF"
  fi
  # Enslave to the walk-in bridge. Idempotent: `master` is a no-op if already
  # set to $BRIDGE, and re-homes if it drifted. A clone tap NEVER lands on
  # vmbr-rn: the name check above and this hard-coded bridge are the two locks.
  local cur
  cur="$(cat "/sys/class/net/$IF/master/ifindex" 2>/dev/null || echo '')"
  if [ "$(cat "/sys/class/net/$BRIDGE/ifindex" 2>/dev/null || echo x)" != "$cur" ]; then
    ip link set dev "$IF" master "$BRIDGE" || die "could not enslave $IF to $BRIDGE"
  fi
  # No L3 address on the tap: it is a pure bridge port.
  sysctl -qw "net.ipv6.conf.$IF.disable_ipv6=1" 2>/dev/null || true
  isolate_port
  ip link set dev "$IF" up
  verify_isolated || die "port isolation on $IF did not verify — refusing to report up"
  install_rules
  if ! verify_rules; then
    install_rules # one retry: the usual cause is a lost xtables race, not a bad rule
    verify_rules || die "guard rules for $BRIDGE did not verify — refusing to report up"
  fi
  msg "up: $IF isolated on $BRIDGE; $GUEST_IP contained (replies only toward labhost; NEW->labhost dropped)"
}

do_down() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  if ip link show "$IF" >/dev/null 2>&1; then
    ip link set dev "$IF" nomaster 2>/dev/null || true
    ip link del dev "$IF"
  fi
  if peers_remain; then
    msg "down: $IF removed; $IN_CHAIN kept (sibling clones still on $BRIDGE)"
  else
    remove_rules
    msg "down: $IF removed; $IN_CHAIN dropped (last win311 clone off $BRIDGE)"
  fi
}

do_show() {
  ip -br addr show "$IF" 2>/dev/null || echo "$IF: absent"
  echo "master=$(basename "$(readlink "/sys/class/net/$IF/master" 2>/dev/null || echo none)")"
  echo "isolated=$(verify_isolated && echo on || echo off)"
  echo "disable_ipv6=$(cat "/proc/sys/net/ipv6/conf/$IF/disable_ipv6" 2>/dev/null || echo '?')"
  iptables -w "$IPT_WAIT" -S "$IN_CHAIN" 2>/dev/null || echo "(no $IN_CHAIN)"
  iptables -w "$IPT_WAIT" -S INPUT | grep -- "$IN_CHAIN" || echo "(INPUT not hooked)"
}

case "${1:-}" in
  up) do_up ;;
  down) do_down ;;
  show) do_show ;;
  *)
    sed -n '2,12p' "$0" >&2
    exit 2
    ;;
esac
