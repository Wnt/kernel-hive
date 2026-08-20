#!/usr/bin/env bash
# retronet-fw — the rules that make "the retronet reaches nothing" a property of
# the box instead of a hope about the upstream router.
#
# Installed on labhost as /usr/local/sbin/retronet-fw by
# scripts/retronet/gateway/provision-gateway-ct.sh, and called from the bridge's
# post-up/post-down in /etc/network/interfaces.d/<bridge>.
#
# WHY IT IS NEEDED AT ALL. The primary guarantee is that the retronet CT has no
# default route, so its own stack refuses before a packet exists. These rules
# are the second lock, for the day someone hands it one — a stray `pct set
# --net0 gw=`, a DHCP client, a helpful future agent. Two things get closed:
#
#   FORWARD  routing THROUGH labhost to the LAN and the internet. labhost runs
#            with ip_forward=1 (the irix and tru64 host-only veths need it) and
#            a FORWARD policy of ACCEPT, so without this the only thing standing
#            between the retronet and the WAN is the absence of a NAT rule.
#   INPUT    labhost's own services. A routed retronet guest could otherwise
#            open the box's LAN listeners — the gallery included — by dialling
#            labhost's LAN address. Only the bridge address stays reachable.
#
# WHAT IT DOES NOT BREAK. Both real consumers of the retronet server reach it
# from labhost ITSELF: the bot's outbound connection and QEMU's slirp
# `guestfwd`, which is a host-side connect() on the station's behalf. Those are
# labhost-initiated, so their replies arrive addressed to the bridge address and
# pass the INPUT allow. Only traffic the retronet STARTS is refused.
#
# usage: retronet-fw up|down|status [bridge]     (default bridge: vmbr-rn)
set -euo pipefail

FWD="RETRONET-FWD"
IN="RETRONET-IN"
BR="${2:-${RN_BRIDGE:-vmbr-rn}}"

# ip6tables is best-effort: the CT is configured ip6=manual (link-local only,
# never routable), so IPv6 is a second lock on a door with no handle. A box
# without ip6tables is not an error.
has6() { command -v ip6tables >/dev/null 2>&1; }

# The bridge's own address, read from the kernel rather than passed in — one
# fewer constant to keep in sync with the interfaces file that calls this.
bridge_addr() { ip -4 -o addr show "$BR" | awk '{print $4}' | cut -d/ -f1 | head -1; }

# Idempotent "this chain is jumped from that built-in chain, exactly once".
ensure_jump() {
  local ipt="$1" builtin="$2" chain="$3"
  "$ipt" -C "$builtin" -j "$chain" 2>/dev/null || "$ipt" -I "$builtin" 1 -j "$chain"
}

fw_up() {
  local addr
  addr="$(bridge_addr)"
  [ -n "$addr" ] || {
    echo "retronet-fw: $BR has no IPv4 address" >&2
    exit 1
  }

  for ipt in iptables $(has6 && echo ip6tables); do
    for chain in "$FWD" "$IN"; do
      "$ipt" -N "$chain" 2>/dev/null || true
      "$ipt" -F "$chain"
    done
    # Retronet CT to retronet CT stays allowed: the plane is meant to grow more
    # than one guest, and br_netfilter (if loaded) puts that traffic in FORWARD.
    "$ipt" -A "$FWD" -i "$BR" -o "$BR" -j RETURN
    "$ipt" -A "$FWD" -i "$BR" -j DROP
    "$ipt" -A "$FWD" -o "$BR" -j DROP
    ensure_jump "$ipt" FORWARD "$FWD"
    ensure_jump "$ipt" INPUT "$IN"
  done

  # INPUT: the bridge address is the whole of labhost as far as the retronet is
  # concerned. IPv4 keeps that one address; IPv6 keeps nothing, because nothing
  # on this plane is configured for IPv6 in the first place.
  iptables -A "$IN" -i "$BR" -d "$addr" -j RETURN
  iptables -A "$IN" -i "$BR" -j DROP
  if has6; then ip6tables -A "$IN" -i "$BR" -j DROP; fi
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
  status) fw_status ;;
  *)
    echo "usage: retronet-fw up|down|status [bridge]" >&2
    exit 2
    ;;
esac
