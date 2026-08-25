#!/bin/bash
# wi-tapnet.sh — a win311 WALK-IN CLONE's link onto the walk-in bridge vmbr-wi.
#
# This is the walk-in sibling of rn-tapnet.sh, NOT a flag on it
# (docs/lab/OPERATING-RULES.md rule 3: fix it in your own stack, never as a
# switch inside someone else's live path). The live station keeps rn-tapnet.sh
# and vmbr-rn untouched; a pool clone gets this script and vmbr-wi, and the two
# planes never meet. Contract: docs/lab/walkin/CONTRACT-LEDGER.md §5.1 (names)
# and §6 (the plane); shape: docs/lab/WALKIN-BRIEF.md §6.1.
#
# WHAT IS DIFFERENT FROM THE RETRONET SIBLING, and why each difference exists:
#
#   1. PER CLONE, NOT PER STATION. rn-tapnet.sh owns one persistent tap for the
#      one live station. A walk-in pool has N clones of the same station alive
#      at once, so the tap name carries the clone ordinal (ledger §5.1:
#      wi-<os>-<n>, e.g. wi-win311-3) and the tap is EPHEMERAL — created by
#      `up` at spawn, deleted by `down` at reap, exactly like the overlay.
#   2. NO RESERVED IP. The retronet guest has a DHCP reservation and a static
#      guard scope. Walk-in clones are ephemeral and lease from CT 951's second
#      scope (10.98.0.100-199, short leases), so the address is not known when
#      the tap comes up. The guard is therefore scoped to the BRIDGE, not to an
#      address — which is also strictly more fail-closed: a clone that ignores
#      DHCP and invents a static address is still inside the chain.
#   3. PORT ISOLATION. Every walk-in tap is `isolated on`, so clones cannot see
#      each other at L2 at all — a kernel-enforced private VLAN, no rules to get
#      wrong (WALKIN-BRIEF §6.1). The gateway's port is the only un-isolated
#      port on the bridge, and this script never touches it.
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
#      there is no path to it, not because a rule says no.
#   2. NO TRANSIT. CT 951 has ip_forward=0 and an nft FORWARD drop between
#      eth0 (vmbr-rn) and eth1 (vmbr-wi), so the dual-homed gateway does not
#      carry a walk-in onto 10.99.0.0/24. Owned by the network-plane lane.
#   3. NO CLONE-TO-CLONE. `bridge link set dev <tap> isolated on`, verified by
#      reading it back out of the kernel below.
#   4. FILTER. The chain below, hooked on vmbr-wi, lets a clone reach labhost
#      ONLY as the ESTABLISHED reply side of a labhost-initiated connection.
#      Every NEW flow a clone starts toward labhost — the gallery on :8443,
#      sshd, anything bound to 0.0.0.0 — is DROPPED. The gateway CT's own
#      address is excepted: it is the plane's service host, not a walk-in.
#
# win311's pointer path does NOT run over this netdev: the warpd agent is on a
# COM1 unix-socket serial chardev (guest-agents/win311/agent.c), which the clone
# namespaces by PATH only. Nothing but the guest's own TCP/IP rides this tap.
#
# Intra-bridge traffic (clone -> CT 10.98.0.2 for DHCP, DNS and HTTP) is pure L2
# with bridge-nf-call-iptables=0, so it never touches these chains — the walk-in
# reaching the corpus is the point.
#
# MEASURED ON THIS PLANE, 2026-08-25 (lane 10 smoke, stand-in gateway on a
# namespaced test bridge because vmbr-wi did not exist yet). TWO FINDINGS THAT
# BLOCK A win311 POOL, and neither is fixed by anything in this script:
#
#   A. THE BAKED DHCP LEASE STRANDS THE CLONE. The golden was re-baked cold with
#      a LIVE lease for 10.99.0.27/24 and no default route. `loadvm golden`
#      restores that lease, so a clone wakes up believing it is 10.99.0.27 and
#      does NOT re-DHCP — it has a valid lease and its T1 has not fired. On
#      10.98.0.0/24 it is therefore off-subnet with no gateway: measured, it
#      ARPs for 10.99.0.2 on the walk-in bridge (4 requests, 0 replies — good
#      containment evidence, the retronet is simply not there) and cannot even
#      answer a ping from 10.98.0.2, because the reply has nowhere to go.
#      `ipconfig /renew_all` through the Run box put NOTHING on the wire.
#      Proven by re-homing the stand-in gateway onto 10.99.0.2/24: the clone
#      then answered 4/4 pings and Netscape 4.08 rendered the corpus origin to
#      "Document: Done" over this tap. So the guest and this script are fine;
#      the SUBNET is the mismatch. Fixes, coordinator's call: re-bake the golden
#      with the lease released (which costs a cold bake and rule 6 care), or
#      give win311's walk-in segment the addressing the golden holds.
#
#   B. EVERY CLONE PRESENTS THE SAME MAC. The ne2k MAC lives in the vmstate, so
#      `mac=` on the command line cannot change it — all pool members come up as
#      the golden's MAC. Measured with two clones on one bridge: the FDB entry
#      moved from wi-win311-1 to wi-win311-2 the moment the second one
#      transmitted, so the gateway's replies follow whichever clone spoke last.
#      Port isolation stops clone<->clone but does nothing about this, because
#      the collision is on the GATEWAY's port. A shared L2 segment cannot host
#      more than one win311 clone. The fix is a segment per clone (a VLAN per
#      port on vmbr-wi with the gateway tagged, or a bridge per clone), which
#      also dissolves finding A — and it is the network plane's to build, not
#      this script's.
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
#   WI_TAP_GATEWAY    default 10.98.0.2 — CT 951's net1, excepted from the chain.
#   WI_TAP_USER       optional uid/name to own the tap, for the per-clone
#                     unprivileged QEMU user. Unset = root-owned, as today.
set -u

BRIDGE="${WI_TAP_BRIDGE:-vmbr-wi}"
# CT 951's net1. It is the plane's DHCP/DNS/:80 origin and is NOT a walk-in
# clone, so it returns from the chain instead of being filtered by it.
GATEWAY="${WI_TAP_GATEWAY:-10.98.0.2}"
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

# Fail-closed filter: a clone may talk to labhost ONLY as the reply side of a
# connection labhost opened. Every NEW flow a clone starts toward labhost is
# dropped. Scoped to the bridge rather than to an address, because a walk-in
# clone's address is a short DHCP lease, not a reservation — and because a clone
# that assigns itself some other address must not fall out of the chain.
# Rebuilt each call.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  # the gateway CT is the plane's service host, not a walk-in: leave it alone.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -s "$GATEWAY" -j RETURN
  # replies to a labhost-initiated probe (labhost dialled the clone first).
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # everything else a clone initiates toward labhost — gallery :8443, ssh :22,
  # any 0.0.0.0 listener reachable via the bridge address — is refused.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # Hook the whole walk-in bridge into INPUT at 1. Re-inserted on every spawn,
  # which keeps it above anything installed at boot.
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -j "$IN_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -I INPUT 1 -i "$BRIDGE" -j "$IN_CHAIN"
}

# Read the isolation back out of the kernel: install_rules cannot be trusted to
# have worked just because it ran (lock contention, a ruleset reload underneath).
verify_rules() {
  local s
  s="$(iptables -w "$IPT_WAIT" -S 2>/dev/null)" || return 1
  grep -qx -- "-A INPUT -i $BRIDGE -j $IN_CHAIN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -s $GATEWAY/32 -j RETURN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -j DROP" <<<"$s" || return 1
}

# The guard chain is shared by every win311 clone (it is scoped to the bridge,
# not to a clone), so `down` on ONE clone must not unhook it while siblings are
# still on the bridge. Only the last win311 tap to leave removes it.
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
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -j "$IN_CHAIN" 2>/dev/null; do :; done
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
  msg "up: $IF isolated on $BRIDGE; clones contained (replies only toward labhost; NEW->labhost dropped)"
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
