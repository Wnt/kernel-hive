#!/usr/bin/env bash
# walkin-fw — labhost's half of the walk-in containment.
#
# Installed on labhost as /usr/local/sbin/walkin-fw by
# scripts/retronet/walkin-net/provision-walkin-net.sh, and called from the
# bridge's post-up/post-down in /etc/network/interfaces.d/vmbr-wi, so it is
# re-asserted on every boot and on every `ifup vmbr-wi`.
#
# THE GOAL, in one line: a walk-in clone reaches the corpus web on the walk-in
# gateway (CT 952) and NOTHING else — not the fleet, not labhost, not the
# internet, not another clone.
#
# The plane's primary defences are topological, and this file is the backstop
# for each of them:
#
#   Lock 1  NO UPLINK      vmbr-wi is `bridge-ports none`. There is no physical
#                          port to leak onto, ever.
#   Lock 2  NO HOST L3     labhost holds NO ADDRESS on vmbr-wi. It is not a
#                          participant on this segment, so there is nothing for
#                          a clone to route through and nothing to dial.
#   Lock 3  NO SECOND LEG  the gateway CT 952 is single-homed on vmbr-wi with no
#                          default route. It cannot forward because it has
#                          nowhere to forward to.
#   Lock 4  L2 ISOLATION   `bridge link set dev <tap> isolated on` per clone tap
#                          (wi-isolate.sh). A Linux bridge switches between its
#                          own ports and bridge-nf-call-iptables is 0 on this
#                          box, so clone<->clone traffic never reaches any
#                          netfilter hook. Port isolation is the only thing that
#                          stops it.
#
# WHAT THIS FILE ADDS ON TOP, and why an addressless bridge is not already
# enough:
#
#   ARP.     The walk-in plane presents 10.99.0.0/24 — the SAME numbering as the
#            retronet, deliberately, so each clone's baked identity is correct
#            (contract ledger §5.3). labhost holds 10.99.0.1/24 on vmbr-rn, and
#            with the default arp_ignore=0 the kernel will answer an ARP request
#            for ANY local address arriving on ANY interface — including one
#            with no address of its own. A clone ARPing for 10.99.0.1 could
#            therefore learn labhost's MAC on vmbr-wi and start sending it
#            packets. `arp_ignore=8` on vmbr-wi refuses to answer for any local
#            address, and the INPUT drop below catches anything that gets past
#            it anyway.
#   FORWARD. labhost runs ip_forward=1 with a FORWARD policy of ACCEPT (the irix
#            and tru64 host-only veths need it). Nothing routes off or onto this
#            bridge.
#   INPUT.   Everything a clone sends to labhost is dropped, unconditionally.
#            There is no ESTABLISHED allowance and no bridge-address exemption:
#            unlike the retronet, labhost is not a participant here and has no
#            business receiving a packet from a walk-in clone at all.
#
# usage: walkin-fw up|down|verify|status [bridge]      (default bridge: vmbr-wi)
set -euo pipefail

FWD="WALKIN-FWD"
IN="WALKIN-IN"
BR="${2:-${WI_BRIDGE:-vmbr-wi}}"

has6() { command -v ip6tables >/dev/null 2>&1; }

ensure_jump() {
  local ipt="$1" builtin="$2" chain="$3"
  "$ipt" -C "$builtin" -j "$chain" 2>/dev/null || "$ipt" -I "$builtin" 1 -j "$chain"
}

# Interface-level hardening. Best-effort by design: a kernel without one of
# these knobs must not stop the firewall from being installed, since the
# firewall is the lock that actually matters.
harden_iface() {
  # 8 = never answer an ARP request for a local address on this interface.
  sysctl -qw "net.ipv4.conf.$BR.arp_ignore=8" 2>/dev/null || true
  # 2 = never advertise a source address that is not on this interface.
  sysctl -qw "net.ipv4.conf.$BR.arp_announce=2" 2>/dev/null || true
  # Strict reverse-path: 10.99.0.0/24 exists on two unconnected bridges, so a
  # packet arriving on the wrong one is a bug worth dropping in the kernel.
  sysctl -qw "net.ipv4.conf.$BR.rp_filter=1" 2>/dev/null || true
  # Nothing on this plane is configured for IPv6, and an addressless bridge
  # would otherwise still carry link-local traffic to labhost.
  sysctl -qw "net.ipv6.conf.$BR.disable_ipv6=1" 2>/dev/null || true
}

fw_up() {
  harden_iface
  for ipt in iptables $(has6 && echo ip6tables); do
    for chain in "$FWD" "$IN"; do
      "$ipt" -N "$chain" 2>/dev/null || true
      "$ipt" -F "$chain"
    done
  done

  # FORWARD — nothing routes off this bridge, and nothing routes onto it. The
  # intra-bridge RETURN is dormant on this box (bridge-nf-call-iptables=0 means
  # bridged frames never reach FORWARD at all); it exists so that loading
  # br_netfilter, which drags them in, cannot silently take the corpus web away
  # from every clone. It does NOT weaken clone<->clone: that is stopped at L2,
  # one layer below anything written here.
  iptables -A "$FWD" -i "$BR" -o "$BR" -j RETURN
  iptables -A "$FWD" -i "$BR" -j DROP
  iptables -A "$FWD" -o "$BR" -j DROP
  # INPUT — labhost receives nothing from this segment.
  iptables -A "$IN" -i "$BR" -j DROP

  if has6; then
    ip6tables -A "$FWD" -i "$BR" -j DROP
    ip6tables -A "$FWD" -o "$BR" -j DROP
    ip6tables -A "$IN" -i "$BR" -j DROP
  fi

  for ipt in iptables $(has6 && echo ip6tables); do
    ensure_jump "$ipt" FORWARD "$FWD"
    ensure_jump "$ipt" INPUT "$IN"
  done

  fw_verify || {
    echo "walkin-fw: rules did not read back — refusing to report up" >&2
    exit 1
  }
}

# Read the containment back out of the kernel. install-then-assume is how a lost
# xtables race becomes an open plane that every message calls "up".
fw_verify() {
  local s
  s="$(iptables -S 2>/dev/null)" || return 1
  grep -qx -- "-A $FWD -i $BR -j DROP" <<<"$s" || return 1
  grep -qx -- "-A $FWD -o $BR -j DROP" <<<"$s" || return 1
  grep -qx -- "-A $IN -i $BR -j DROP" <<<"$s" || return 1
  grep -qx -- "-A FORWARD -j $FWD" <<<"$s" || return 1
  grep -qx -- "-A INPUT -j $IN" <<<"$s" || return 1
  # labhost must own no address here: an address would make it a participant,
  # and on a plane that reuses the retronet's numbering it would also be a
  # second route to 10.99.0.0/24.
  [ -z "$(ip -4 -o addr show "$BR" 2>/dev/null)" ] || return 1
}

fw_down() {
  for ipt in iptables $(has6 && echo ip6tables); do
    "$ipt" -D FORWARD -j "$FWD" 2>/dev/null || true
    "$ipt" -D INPUT -j "$IN" 2>/dev/null || true
    for chain in "$FWD" "$IN"; do
      "$ipt" -F "$chain" 2>/dev/null || true
      "$ipt" -X "$chain" 2>/dev/null || true
    done
  done
}

fw_status() {
  echo "== $BR =="
  ip -br addr show "$BR" 2>/dev/null || echo "(absent)"
  local k
  for k in arp_ignore arp_announce rp_filter; do
    printf '  %-13s %s\n' "$k" "$(cat "/proc/sys/net/ipv4/conf/$BR/$k" 2>/dev/null || echo '?')"
  done
  for chain in FORWARD "$FWD" INPUT "$IN"; do
    echo "== iptables $chain =="
    iptables -S "$chain" 2>/dev/null || echo "(absent)"
  done
}

case "${1:-status}" in
  up) fw_up ;;
  down) fw_down ;;
  verify) fw_verify && echo "walkin-fw: $BR contained (no host address, FORWARD closed, INPUT dropped)" ;;
  status) fw_status ;;
  *)
    echo "usage: walkin-fw up|down|verify|status [bridge]" >&2
    exit 2
    ;;
esac
