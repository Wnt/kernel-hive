#!/bin/bash
# tapnet.sh — the IRIX tile's tap link, in one of two modes.
#
# The guest is IRIX 6.5 from 2003 with a root-owned Apache in it, 30+ listeners
# bound to `*`, and seven accounts with NO passwords. The thing that must never
# happen is something on the LAN OPENING A CONNECTION TO IT. Everything below is
# arranged around that one sentence.
#
#   SANDBOX  (IRIX_NET_EGRESS=off, the default)
#     A /30 point-to-point tap between this host and the guest and nothing else:
#     no default route in the guest, no NAT, no bridge, no forwarding. The guest
#     can reach 172.31.20.1 and cannot reach the LAN, the internet, this host's
#     own LAN address, or any other guest.
#
#   EGRESS   (IRIX_NET_EGRESS=on)
#     The guest may INITIATE connections outward — LAN and internet — through a
#     masquerade on $WAN. Nothing can initiate a connection INWARD: the return
#     path is ESTABLISHED,RELATED only, there is no DNAT and no port forward
#     anywhere, and the guest's address is not routable from the LAN in the first
#     place (it is RFC1918 space behind a NAT with no inbound rule). Forwarding
#     is enabled per-interface for this pair only, never as a blanket global.
#
# In BOTH modes the containment is layered so that no single failure opens
# inbound:
#
#   1. TOPOLOGY. The tap is never enslaved to a bridge (tapnet refuses to run if
#      it finds a master), so the guest is never on the LAN's L2.
#   2. ROUTING. Per-interface forwarding is 0 in sandbox mode, and in egress mode
#      it is set only on the tap and $WAN.
#   3. FILTER. Fail-closed rules in this tile's own chains, ending in DROP.
#      The INPUT chain is identical in both modes: the guest may address the host
#      end of the /30 and NOTHING else on this host — not even its LAN address.
#      IPv6 is disabled on the interface and dropped in both modes.
#
# Idempotent, and called from x11-runtime.sh on EVERY launch — that is what
# makes it survive both a tile relaunch and a host reboot without a separate
# systemd unit. Run standalone as:
#
#   tapnet.sh up   [ifname] [host_cidr] [guest_ip]
#   tapnet.sh down [ifname]
#   tapnet.sh show [ifname]
#   tapnet.sh claim <tag>          # atomically take a free SLOT (tap + /30),
#                                  # bring it up, print eval-able IRIX_TAP_*
#   tapnet.sh release <slot|if>    # drop the tap and free the slot
#   tapnet.sh slots                # what is claimed right now, and by whom
#   tapnet.sh gc                   # reap slots whose owner process is gone
set -u

IF="${2:-${IRIX_TAP_IF:-irixtap0}}"
HOST_CIDR="${3:-${IRIX_TAP_HOST_CIDR:-172.31.20.1/30}}"
GUEST_IP="${4:-${IRIX_TAP_GUEST_IP:-172.31.20.2}}"
HOST_IP="${HOST_CIDR%%/*}"
# Outbound-only egress. OFF is the historical host-only sandbox and stays the
# default: turning this on is a deliberate, documented decision (see
# docs/guests/irix.md), not something a launcher should acquire by accident.
EGRESS="${IRIX_NET_EGRESS:-off}"
# The uplink the guest's traffic is masqueraded out of. Auto = whichever
# interface this host's own default route uses (vmbr0 on the lab box).
WAN="${IRIX_NET_WAN:-auto}"
# PER-INTERFACE chain names. They used to be shared (`IRIXNET-IN`), and with two
# agents running clones side by side that was a real containment failure, not a
# tidiness issue: `install_rules` FLUSHES its chains and `remove_rules` DELETES
# them, so one rig's teardown silently emptied the other rig's INPUT filter and
# left its guest able to reach the host's LAN address (observed 2026-08-03, and
# only caught because the adversarial test was re-run). One chain set per tap.
chains_for() { # per-interface chain names (<=28 chars, iptables' limit)
  FWD_CHAIN="IRIXNET-FWD-$1"
  IN_CHAIN="IRIXNET-IN-$1"
  NAT_CHAIN="IRIXNET-NAT-$1"
}
chains_for "$IF"

# Slot arithmetic for the clone allocator. Slot N owns interface `irixtapN` and
# the /30 at 172.31.20.(4N): host .(4N+1), guest .(4N+2). Slot 0 is therefore
# exactly the production tile's irixtap0 / 172.31.20.1 / 172.31.20.2, and
# `claim` never hands slot 0 out — a clone cannot take the exhibit's addresses
# by accident, and the tile itself claims nothing.
CLAIM_ROOT="${IRIX_TAP_CLAIMS:-/run/irix-taps}"
IF_PREFIX="${IRIX_TAP_PREFIX:-irixtap}"
SLOT_MAX="${IRIX_TAP_SLOT_MAX:-62}"
SLOT_NET="${IRIX_TAP_SLOT_NET:-172.31.20}"
# Seconds to wait for the xtables lock. WITHOUT this every iptables call is
# "try once, give up": concurrent `up`s race the lock, lose, and the tap comes
# up with NO fail-closed rules while this script still prints "up". Measured on
# 8 simultaneous claims, not theoretical — which is also why install_rules is
# read back out of the kernel by verify_rules before `up` reports success.
IPT_WAIT="${IRIX_TAP_IPT_WAIT:-15}"

msg() { echo "tapnet: $*"; }
die() {
  echo "tapnet: $*" >&2
  exit 1
}

# The uplink interface, resolved once. Asking the routing table is better than
# hardcoding vmbr0: if this host's default route ever moves, the masquerade
# follows it instead of silently NATing out of an interface that is not there.
resolve_wan() {
  [ "$WAN" = auto ] || return 0
  WAN="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
  [ -n "$WAN" ] || die "IRIX_NET_EGRESS=on but no default route to masquerade out of"
}

# Per-interface kernel knobs. In sandbox mode `forwarding=0` is the routing-layer
# half of the isolation; in egress mode it is 1 on this pair ONLY, which is why
# it is set here per interface and the box's global ip_forward is neither read
# nor written. The rest stops the tap from being talked into redirects or from
# acquiring an IPv6 link-local that could carry traffic the v4 rules never see.
harden_sysctls() {
  local fwd=0
  [ "$EGRESS" = on ] && fwd=1
  sysctl -qw "net.ipv4.conf.$IF.forwarding=$fwd" 2>/dev/null || true
  [ "$EGRESS" = on ] && sysctl -qw "net.ipv4.conf.$WAN.forwarding=1" 2>/dev/null
  sysctl -qw "net.ipv4.conf.$IF.rp_filter=1" 2>/dev/null || true
  sysctl -qw "net.ipv4.conf.$IF.accept_redirects=0" 2>/dev/null || true
  sysctl -qw "net.ipv4.conf.$IF.send_redirects=0" 2>/dev/null || true
  sysctl -qw "net.ipv4.conf.$IF.proxy_arp=0" 2>/dev/null || true
  sysctl -qw "net.ipv6.conf.$IF.disable_ipv6=1" 2>/dev/null || true
}

# Fail-closed filter rules, in chains this tile owns so nothing here can be
# confused with (or clobbered by) another agent's rules. Rebuilt from empty on
# every call, which is what makes re-running safe.
install_rules() {
  local ipt
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    "$ipt" -w "$IPT_WAIT" -N "$FWD_CHAIN" 2>/dev/null || true
    "$ipt" -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
    "$ipt" -w "$IPT_WAIT" -F "$FWD_CHAIN"
    "$ipt" -w "$IPT_WAIT" -F "$IN_CHAIN"
    # v4 egress mode punches exactly two holes in the forward path, and the
    # asymmetry between them IS the security property: NEW is accepted only in
    # the guest->WAN direction, so a connection can only ever be opened by the
    # guest. ip6tables never gets them — the guest has no IPv6 at all.
    if [ "$ipt" = iptables ] && [ "$EGRESS" = on ]; then
      "$ipt" -w "$IPT_WAIT" -A "$FWD_CHAIN" -i "$IF" -o "$WAN" -s "$GUEST_IP" \
        -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
      "$ipt" -w "$IPT_WAIT" -A "$FWD_CHAIN" -i "$WAN" -o "$IF" -d "$GUEST_IP" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    fi
    # Everything else crossing this interface is dropped, in either direction.
    "$ipt" -w "$IPT_WAIT" -A "$FWD_CHAIN" -i "$IF" -j DROP
    "$ipt" -w "$IPT_WAIT" -A "$FWD_CHAIN" -o "$IF" -j DROP
    while "$ipt" -w "$IPT_WAIT" -D FORWARD -j "$FWD_CHAIN" 2>/dev/null; do :; done
    "$ipt" -w "$IPT_WAIT" -I FORWARD 1 -j "$FWD_CHAIN"
    while "$ipt" -w "$IPT_WAIT" -D INPUT -i "$IF" -j "$IN_CHAIN" 2>/dev/null; do :; done
    "$ipt" -w "$IPT_WAIT" -I INPUT 1 -i "$IF" -j "$IN_CHAIN"
    # Legacy shared-chain hook from before the per-interface split, if any.
    while "$ipt" -w "$IPT_WAIT" -D INPUT -i "$IF" -j IRIXNET-IN 2>/dev/null; do :; done
  done
  # Source NAT for the guest, in this tile's own chain. Scoped to the guest's
  # single address and to $WAN, so it can never masquerade anything else.
  iptables -w "$IPT_WAIT" -t nat -N "$NAT_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -t nat -F "$NAT_CHAIN"
  while iptables -w "$IPT_WAIT" -t nat -D POSTROUTING -j "$NAT_CHAIN" 2>/dev/null; do :; done
  if [ "$EGRESS" = on ]; then
    iptables -w "$IPT_WAIT" -t nat -A "$NAT_CHAIN" -s "$GUEST_IP" -o "$WAN" -j MASQUERADE
    iptables -w "$IPT_WAIT" -t nat -I POSTROUTING 1 -j "$NAT_CHAIN"
  fi
  # v4: the guest may talk to the host end of the /30 and to nothing else — not
  # even to this host's own LAN address, which it would otherwise reach the
  # moment anyone gave it a route.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -s "$GUEST_IP" -d "$HOST_IP" -j RETURN
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # v6: the interface has IPv6 disabled; drop anything that appears regardless.
  command -v ip6tables >/dev/null 2>&1 && ip6tables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  return 0
}

# Read the isolation back out of the kernel. install_rules cannot be trusted to
# have worked just because it ran: iptables fails per call (lock contention, a
# ruleset reload underneath us), and a tap whose rules are missing is FAIL-OPEN
# while every message on stdout still says "up". Checked in both modes — the
# egress ACCEPTs are additions ABOVE these rules, never replacements for them.
verify_rules() {
  local s
  s="$(iptables -w "$IPT_WAIT" -S 2>/dev/null)" || return 1
  grep -qx -- "-A INPUT -i $IF -j $IN_CHAIN" <<<"$s" || return 1
  grep -qx -- "-A FORWARD -j $FWD_CHAIN" <<<"$s" || return 1
  grep -qx -- "-A $FWD_CHAIN -i $IF -j DROP" <<<"$s" || return 1
  grep -qx -- "-A $FWD_CHAIN -o $IF -j DROP" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -s $GUEST_IP/32 -d $HOST_IP/32 -j RETURN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -j DROP" <<<"$s" || return 1
}

remove_rules() {
  local ipt
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    while "$ipt" -w "$IPT_WAIT" -D FORWARD -j "$FWD_CHAIN" 2>/dev/null; do :; done
    while "$ipt" -w "$IPT_WAIT" -D INPUT -i "$IF" -j "$IN_CHAIN" 2>/dev/null; do :; done
    "$ipt" -w "$IPT_WAIT" -F "$FWD_CHAIN" 2>/dev/null || true
    "$ipt" -w "$IPT_WAIT" -F "$IN_CHAIN" 2>/dev/null || true
    "$ipt" -w "$IPT_WAIT" -X "$FWD_CHAIN" 2>/dev/null || true
    "$ipt" -w "$IPT_WAIT" -X "$IN_CHAIN" 2>/dev/null || true
  done
  while iptables -w "$IPT_WAIT" -t nat -D POSTROUTING -j "$NAT_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -t nat -F "$NAT_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -t nat -X "$NAT_CHAIN" 2>/dev/null || true
}

do_up() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  case "$IF" in
    *[!a-zA-Z0-9_-]* | '') die "invalid interface name: $IF" ;;
  esac
  # IFNAMSIZ is 16 including the NUL, and both the kernel and MAME's
  # MAME_TAP_IFNAME path TRUNCATE silently — an over-long name is a collision
  # waiting to happen, not a cosmetic problem.
  [ "${#IF}" -le 15 ] || die "interface name longer than 15 chars: $IF"
  case "$EGRESS" in
    on | off) ;;
    *) die "IRIX_NET_EGRESS must be on or off, got: $EGRESS" ;;
  esac
  [ "$EGRESS" = on ] && resolve_wan
  # A PERSISTENT tap (no owner/group, no user): it exists before MAME starts and
  # survives MAME exiting, so the host end keeps its address across a relaunch
  # and the addressing is not a function of process lifetime.
  if ! ip link show "$IF" >/dev/null 2>&1; then
    ip tuntap add dev "$IF" mode tap || die "could not create tap $IF"
    msg "created tap $IF"
  fi
  # NEVER a bridge port. If something enslaved it, that is a containment
  # failure and the right move is to refuse, not to fix it silently.
  if [ -e "/sys/class/net/$IF/master" ]; then
    die "$IF is enslaved to a bridge — refusing (this link must never be bridged)"
  fi
  ip addr replace "$HOST_CIDR" dev "$IF"
  ip link set dev "$IF" up
  harden_sysctls
  install_rules
  if ! verify_rules; then
    install_rules # one retry: the usual cause is a lost race, not a bad rule
    verify_rules || {
      ip link set dev "$IF" down 2>/dev/null || true
      die "isolation rules for $IF did not verify — link left DOWN, refusing to report it up"
    }
  fi
  if [ "$EGRESS" = on ]; then
    msg "up: $IF host=$HOST_CIDR guest=$GUEST_IP" \
      "(EGRESS via $WAN: guest may DIAL OUT to the LAN and the internet;" \
      "nothing may dial IN — no DNAT, no port forward, return path is" \
      "ESTABLISHED,RELATED only)"
  else
    msg "up: $IF host=$HOST_CIDR guest=$GUEST_IP (host-only; no forwarding, no NAT, no bridge)"
  fi
}

do_down() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  remove_rules
  ip link show "$IF" >/dev/null 2>&1 && ip link del dev "$IF"
  msg "down: $IF removed"
}

do_show() {
  echo "mode=$([ "$EGRESS" = on ] && echo egress-outbound-only || echo sandbox-host-only)"
  ip -br addr show "$IF" 2>/dev/null || echo "$IF: absent"
  echo "forwarding=$(cat "/proc/sys/net/ipv4/conf/$IF/forwarding" 2>/dev/null || echo '?')" \
    "disable_ipv6=$(cat "/proc/sys/net/ipv6/conf/$IF/disable_ipv6" 2>/dev/null || echo '?')"
  iptables -w "$IPT_WAIT" -S "$FWD_CHAIN" 2>/dev/null || echo "(no $FWD_CHAIN)"
  iptables -w "$IPT_WAIT" -S "$IN_CHAIN" 2>/dev/null || echo "(no $IN_CHAIN)"
  iptables -w "$IPT_WAIT" -t nat -S "$NAT_CHAIN" 2>/dev/null || echo "(no $NAT_CHAIN)"
  iptables -w "$IPT_WAIT" -S FORWARD | grep -- "$FWD_CHAIN" || echo "(FORWARD not hooked)"
  iptables -w "$IPT_WAIT" -S INPUT | grep -- "$IN_CHAIN" || echo "(INPUT not hooked)"
  iptables -w "$IPT_WAIT" -t nat -S POSTROUTING | grep -- "$NAT_CHAIN" || echo "(POSTROUTING not hooked)"
}

# --- slot allocation --------------------------------------------------------
# The allocator is `mkdir`, and nothing else: mkdir either creates the directory
# or fails, atomically, for exactly one caller. Two agents starting in the same
# millisecond therefore cannot come away with the same tap — which a
# check-then-create ("is irixtap3 free? then make it") cannot promise, and which
# is precisely the collision that cost the last measurement campaign its
# concurrent workloads. Same principle as scripts/lib/xvfb-alloc.sh, where the
# claim is the X server's own atomic socket bind.

slot_if() { echo "$IF_PREFIX$1"; }
slot_host_cidr() { echo "$SLOT_NET.$((4 * $1 + 1))/30"; }
slot_guest_ip() { echo "$SLOT_NET.$((4 * $1 + 2))"; }

CLAIM_DIR=""
CLAIM_OK=0
# Any exit before the slot is fully up gives the slot back. Without this a
# refused or failed `up` strands the slot forever and the pool silently shrinks.
claim_cleanup() {
  [ -n "$CLAIM_DIR" ] || return 0
  [ "$CLAIM_OK" = 1 ] && return 0
  rm -f -- "$CLAIM_DIR/claim"
  rmdir "$CLAIM_DIR" 2>/dev/null || true
}

do_claim() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  trap claim_cleanup EXIT
  local tag="${2:-clone}" n dir ifname
  case "$tag" in *[!a-zA-Z0-9_.-]* | '') die "invalid tag: $tag" ;; esac
  mkdir -p "$CLAIM_ROOT"
  for ((n = 1; n <= SLOT_MAX; n++)); do
    dir="$CLAIM_ROOT/$n"
    mkdir "$dir" 2>/dev/null || continue # <- the atomic claim
    ifname="$(slot_if "$n")"
    # A tap that exists with no claim behind it belongs to something older than
    # this protocol, or to a rig that died before `gc` reaped it. Never adopt
    # one: hand the slot back and move on.
    if ip link show "$ifname" >/dev/null 2>&1; then
      rmdir "$dir" 2>/dev/null || true
      continue
    fi
    CLAIM_DIR="$dir"
    IF="$ifname"
    HOST_CIDR="$(slot_host_cidr "$n")"
    GUEST_IP="$(slot_guest_ip "$n")"
    HOST_IP="${HOST_CIDR%%/*}"
    chains_for "$IF"
    {
      echo "slot=$n"
      echo "if=$IF"
      echo "host_cidr=$HOST_CIDR"
      echo "guest_ip=$GUEST_IP"
      echo "tag=$tag"
      echo "pid=${IRIX_TAP_OWNER_PID:-$PPID}"
      echo "claimed=$(date '+%F %T')"
    } >"$dir/claim"
    do_up >&2
    CLAIM_OK=1
    echo "IRIX_TAP_SLOT=$n"
    echo "IRIX_TAP_IF=$IF"
    echo "IRIX_TAP_HOST_CIDR=$HOST_CIDR"
    echo "IRIX_TAP_GUEST_IP=$GUEST_IP"
    return 0
  done
  die "no free tap slot in 1..$SLOT_MAX"
}

release_slot() { # $1 = slot number
  local n="$1"
  [ "$n" -gt 0 ] 2>/dev/null || die "refusing to release slot 0 (the production tile)"
  IF="$(slot_if "$n")"
  chains_for "$IF"
  do_down
  rm -f -- "$CLAIM_ROOT/$n/claim"
  rmdir "$CLAIM_ROOT/$n" 2>/dev/null || true
  msg "released slot $n"
}

do_release() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  local arg="${2:-}"
  case "$arg" in
    '') die "usage: tapnet.sh release <slot|ifname>" ;;
    "$IF_PREFIX"*) arg="${arg#"$IF_PREFIX"}" ;;
  esac
  case "$arg" in *[!0-9]* | '') die "not a slot: ${2:-}" ;; esac
  release_slot "$arg"
}

do_slots() {
  local dir n p
  [ -d "$CLAIM_ROOT" ] || {
    echo "(no claims)"
    return 0
  }
  for dir in "$CLAIM_ROOT"/*; do
    [ -f "$dir/claim" ] || continue
    n="$(basename "$dir")"
    p="$(sed -n 's/^pid=//p' "$dir/claim")"
    echo "slot $n: $(tr '\n' ' ' <"$dir/claim") alive=$(
      { [ -n "$p" ] && [ -e "/proc/$p" ] && echo yes; } || echo no
    )"
  done
}

# Reap slots whose owner process is gone. Deliberately NOT automatic inside
# `claim`: an unclaimed-but-existing tap is a symptom, and silently recycling it
# would hide exactly the leak this is meant to surface.
do_gc() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  local dir n p
  [ -d "$CLAIM_ROOT" ] || return 0
  for dir in "$CLAIM_ROOT"/*; do
    [ -f "$dir/claim" ] || continue
    n="$(basename "$dir")"
    p="$(sed -n 's/^pid=//p' "$dir/claim")"
    if [ -n "$p" ] && [ -e "/proc/$p" ]; then continue; fi
    msg "gc: slot $n owner pid ${p:-?} is gone"
    release_slot "$n"
  done
}

case "${1:-}" in
  up) do_up ;;
  down) do_down ;;
  show) do_show ;;
  claim) do_claim "$@" ;;
  release) do_release "$@" ;;
  slots) do_slots ;;
  gc) do_gc ;;
  *)
    sed -n '2,60p' "$0" >&2
    exit 2
    ;;
esac
