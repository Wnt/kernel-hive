#!/usr/bin/env bash
# walkin-fw — labhost's half of the walk-in containment.
#
# Installed on labhost as /usr/local/sbin/walkin-fw by
# scripts/retronet/walkin-net/provision-walkin-net.sh, and called from the
# bridge's post-up/post-down in /etc/network/interfaces.d/vmbr-wi, so it is
# re-asserted on every boot and on every `ifup vmbr-wi`.
#
# THE GOAL, in one line: a walk-in clone reaches the corpus web on the gateway
# CT and NOTHING else — not the fleet, not labhost, not the internet, not
# another clone.
#
# This script owns two of the four locks. The other two live elsewhere and this
# file does not substitute for either:
#
#   Lock 1  TOPOLOGY   vmbr-wi has `bridge-ports none` — no uplink, ever.
#   Lock 2  ADDRESSING the walk-in DHCP scope sends NO router option (option 3),
#                      so a clone has no default route at all.
#   Lock 3  THIS FILE  FORWARD: nothing routes through labhost off vmbr-wi, in
#                      either direction. labhost runs ip_forward=1 with a
#                      FORWARD policy of ACCEPT (the irix/tru64 host-only veths
#                      need it), so without this the only thing between a clone
#                      and the LAN is the absence of a NAT rule.
#                      INPUT: labhost's own services. Unlike the retronet's
#                      RETRONET-IN, which keeps the bridge address reachable,
#                      the walk-in plane keeps NOTHING: a clone may talk to
#                      labhost only as the ESTABLISHED reply side of a
#                      connection labhost opened. Every NEW flow a clone starts
#                      toward any labhost address is dropped.
#   Lock 4  L2         `bridge link set dev <tap> isolated on` on every clone
#                      tap (see wi-isolate.sh). A Linux bridge switches between
#                      its own ports, and bridge-nf-call-iptables is 0 on this
#                      box, so clone<->clone traffic never reaches these chains.
#                      Port isolation is the ONLY thing that stops it.
#
# WHY LABHOST KEEPS AN ADDRESS ON THE BRIDGE AT ALL. 10.98.0.1/24 exists so
# labhost can dial a clone (an exec/probe channel, the same shape the retronet
# uses at 10.99.0.1). The INPUT chain below makes that one-way: labhost may
# open a connection to a clone; a clone may never open one to labhost.
#
# usage: walkin-fw up|down|status [bridge]      (default bridge: vmbr-wi)
set -euo pipefail

FWD="WALKIN-FWD"
IN="WALKIN-IN"
BR="${2:-${WI_BRIDGE:-vmbr-wi}}"
# The gateway CT's address on this bridge. Clone<->gateway is pure L2 on a box
# with bridge-nf-call-iptables=0, so these two RETURNs are dormant today; they
# exist so that loading br_netfilter (which drags bridged frames into FORWARD)
# cannot silently take the corpus web away from every clone.
GW="${WI_GATEWAY_IP:-10.98.0.2}"

has6() { command -v ip6tables >/dev/null 2>&1; }

ensure_jump() {
  local ipt="$1" builtin="$2" chain="$3"
  "$ipt" -C "$builtin" -j "$chain" 2>/dev/null || "$ipt" -I "$builtin" 1 -j "$chain"
}

fw_up() {
  for ipt in iptables $(has6 && echo ip6tables); do
    for chain in "$FWD" "$IN"; do
      "$ipt" -N "$chain" 2>/dev/null || true
      "$ipt" -F "$chain"
    done
  done

  # FORWARD — nothing routes off this bridge, and nothing routes onto it.
  iptables -A "$FWD" -i "$BR" -o "$BR" -d "$GW" -j RETURN
  iptables -A "$FWD" -i "$BR" -o "$BR" -s "$GW" -j RETURN
  iptables -A "$FWD" -i "$BR" -j DROP
  iptables -A "$FWD" -o "$BR" -j DROP
  # INPUT — replies only. No allowance for the bridge address: a clone has no
  # business dialling labhost, including the gallery, sshd or any 0.0.0.0
  # listener reachable through 10.98.0.1.
  iptables -A "$IN" -i "$BR" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  iptables -A "$IN" -i "$BR" -j DROP

  # IPv6 keeps nothing at all: nothing on this plane is configured for IPv6.
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

# Read the containment back out of the kernel. install-then-assume is how a
# lost xtables race becomes an open plane that every message calls "up".
fw_verify() {
  local s
  s="$(iptables -S 2>/dev/null)" || return 1
  grep -qx -- "-A $FWD -i $BR -j DROP" <<<"$s" || return 1
  grep -qx -- "-A $FWD -o $BR -j DROP" <<<"$s" || return 1
  grep -qx -- "-A $IN -i $BR -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" <<<"$s" || return 1
  grep -qx -- "-A $IN -i $BR -j DROP" <<<"$s" || return 1
  grep -qx -- "-A FORWARD -j $FWD" <<<"$s" || return 1
  grep -qx -- "-A INPUT -j $IN" <<<"$s" || return 1
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
  for chain in FORWARD "$FWD" INPUT "$IN"; do
    echo "== iptables $chain =="
    iptables -S "$chain" 2>/dev/null || echo "(absent)"
  done
}

case "${1:-status}" in
  up) fw_up ;;
  down) fw_down ;;
  verify) fw_verify && echo "walkin-fw: $BR contained" ;;
  status) fw_status ;;
  *)
    echo "usage: walkin-fw up|down|verify|status [bridge]" >&2
    exit 2
    ;;
esac
