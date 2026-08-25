#!/usr/bin/env bash
# wi-clonecell — one walk-in clone's PRIVATE L2 CELL, and the NAT that lets
# identical machines share one plane.
#
# Installed on labhost as /usr/local/sbin/wi-clonecell by
# scripts/retronet/walkin-net/provision-walkin-net.sh (bridge step). The broker
# (scripts/serve/walkin/clone.py) calls it around each clone's tapnet script.
#
# WHY IT EXISTS. `loadvm` restores a NIC's MAC from saved device state — `mac=`
# on the command line cannot override it, and the device set may not change
# (OPERATING-RULES rule 6) — so EVERY clone of one station is identical on the
# wire: same MAC, and the same baked IP its golden held on vmbr-rn. Put two of
# them on one bridge and the FDB entry for the shared MAC follows whichever
# transmitted last, while the gateway sees one host where there are two. That
# was ledger §5.4's argument for poolSize 1. This helper is what replaced it:
#
#   * Each clone gets its OWN bridge (`wibr<slot>`), so identical MACs never
#     share an FDB. The clone's tap is the only guest port on it.
#   * A NAT namespace (`wicell<slot>`) joins that cell to vmbr-wi through a veth
#     pair. On the way out, the guest's baked source address is SNATed to a
#     UNIQUE per-slot peer address (10.99.0.<slot-100>, so slots 152-200 map to
#     .52-.100 — reserved in ledger §6). The guest keeps believing it is .19;
#     the gateway sees a distinct peer per clone. CT 952 is NOT modified at all.
#   * Inside the cell, the namespace answers ARP for exactly one address — the
#     gateway, 10.99.0.2 — via a pneigh proxy entry. Nothing else resolves, so
#     the fleet's addresses fail exactly as they fail on the flat plane.
#
# CONTAINMENT — the cell REPLACES port isolation for the guest and adds a lock:
#
#   * The cell's outer veth is a port of vmbr-wi and is `wi-isolate on`-ed, so
#     cell<->cell traffic is dropped at L2 exactly as clone taps were.
#   * The namespace's FORWARD chain is fail-closed: the guest reaches
#     10.99.0.2 and NOTHING else — the first rule-based lock a clone's packets
#     meet, one layer above the topology that already contains them.
#   * The namespace's INPUT is fail-closed too: the guest cannot dial the
#     namespace itself (nothing listens, and the policy makes that a fact).
#   * The cell bridge is hardened like vmbr-wi (arp_ignore=8 etc), and
#     labhost's walkin-fw drops `wibr+` in INPUT/FORWARD as the same backstop
#     it keeps for vmbr-wi. `verify` checks that backstop is actually loaded.
#
# THE PRIME. A golden restores with a WARM ARP CACHE from its retronet capture:
# it believes 10.99.0.2 lives at CT 951's MAC, which exists on neither vmbr-wi
# nor any cell. On the flat plane wi-warm-arp had CT 952 ping the clone; inside
# a cell CT 952's ARP cannot reach the guest (the namespace terminates L2), so
# the CELL speaks first: `prime` broadcasts an ARP request whose sender fields
# are 10.99.0.2 + the cell's inner MAC. Per RFC 826 the guest merges the sender
# into its existing entry — the same repair, from one hop closer. The guest's
# ARP REPLY is the proof the repair landed (it is addressed to the very MAC the
# guest just learned), and `prime` also LEARNS the guest's MAC from that reply
# and pins it in the namespace, so the return path never depends on the guest
# answering a 0.0.0.0 probe. The guest must be RUNNING to answer — the caller
# resumes it under a wake lease first, exactly as for wi-warm-arp.
#
#   wi-clonecell up     <slot> <guest-ip>   build the cell; prints the bridge name
#   wi-clonecell prime  <slot> <guest-ip> [--wait SECS]   repair + prove the guest's ARP
#   wi-clonecell down   <slot>             tear the whole cell down (idempotent)
#   wi-clonecell verify <slot>             read every lock back out of the kernel
#   wi-clonecell ls                        every cell on the box, by slot
set -uo pipefail

GW="${WI_GATEWAY_IP:-10.99.0.2}"
WI_BRIDGE="${WI_BRIDGE:-vmbr-wi}"
SLOT_MIN=152
SLOT_MAX=200

die() {
  echo "wi-clonecell: $*" >&2
  exit 1
}
msg() { echo "wi-clonecell: $*"; }

check_slot() {
  case "${1:-}" in *[!0-9]* | '') die "not a slot: '${1:-}'" ;; esac
  [ "$1" -ge $SLOT_MIN ] && [ "$1" -le $SLOT_MAX ] || die "slot $1 outside $SLOT_MIN-$SLOT_MAX (ledger §5.1)"
}

check_ip() {
  case "${1:-}" in
    10.99.0.*) : ;;
    *) die "guest ip '${1:-}' is not on the walk-in plane's 10.99.0.0/24" ;;
  esac
  [ "$1" != "$GW" ] || die "guest ip may not be the gateway"
}

names() { # slot -> BR NS VI VO PEER
  BR="wibr$1"
  NS="wicell$1"
  VI="wiv$1i"
  VO="wiv$1o"
  PEER="10.99.0.$(($1 - 100))"
}

nsx() { ip netns exec "$NS" "$@"; }

harden_bridge() { # same knobs walkin-fw puts on vmbr-wi, same reasons
  sysctl -qw "net.ipv4.conf.$BR.arp_ignore=8" 2>/dev/null || true
  sysctl -qw "net.ipv4.conf.$BR.arp_announce=2" 2>/dev/null || true
  sysctl -qw "net.ipv4.conf.$BR.rp_filter=1" 2>/dev/null || true
  sysctl -qw "net.ipv6.conf.$BR.disable_ipv6=1" 2>/dev/null || true
}

cell_up() {
  local slot="$1" gip="$2"
  check_slot "$slot"
  check_ip "$gip"
  names "$slot"
  [ "$(id -u)" = 0 ] || die "must run as root on labhost"
  ip link show "$WI_BRIDGE" >/dev/null 2>&1 || die "$WI_BRIDGE absent — provision-walkin-net.sh --apply first"
  # Rebuild from scratch rather than reconcile: a cell is per-clone and
  # throwaway, and a half-state cell is exactly what a failed build leaves.
  cell_down "$slot" quiet
  ip link add "$BR" type bridge || die "could not create $BR"
  harden_bridge
  ip link set "$BR" up
  ip netns add "$NS" || die "netns add $NS"
  nsx ip link set lo up
  nsx sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.arp_ignore=1 \
    net.ipv4.conf.default.arp_ignore=1 net.ipv6.conf.all.disable_ipv6=1 \
    net.ipv6.conf.default.disable_ipv6=1 || die "netns sysctls"
  # Inner leg: cell bridge <-> namespace. No address — the namespace is not a
  # host the guest can dial, it only forwards. pneigh makes it answer ARP for
  # the gateway and NOTHING else.
  ip link add "$VI" type veth peer name in0 netns "$NS" || die "veth $VI"
  ip link set "$VI" master "$BR" up
  nsx ethtool -K in0 tx off rx off >/dev/null 2>&1 || true # era guests checksum in software
  nsx ip link set in0 up
  nsx ip neigh add proxy "$GW" dev in0 || die "pneigh $GW on in0"
  nsx ip route add "$gip/32" dev in0 || die "host route $gip"
  # Outer leg: namespace <-> vmbr-wi, isolated like any clone tap was.
  ip link add "$VO" type veth peer name out0 netns "$NS" || die "veth $VO"
  ip link set "$VO" master "$WI_BRIDGE" up
  /usr/local/sbin/wi-isolate on "$VO" >/dev/null || die "wi-isolate on $VO"
  nsx ethtool -K out0 tx off rx off >/dev/null 2>&1 || true
  nsx ip addr add "$PEER/24" dev out0 || die "peer address $PEER"
  nsx ip link set out0 up
  # The NAT, and the fail-closed rules around it. The guest may reach the
  # gateway; the gateway's replies may come back; nothing else moves.
  nsx iptables -t nat -A POSTROUTING -o out0 -s "$gip" -j SNAT --to-source "$PEER" || die "SNAT"
  nsx iptables -P FORWARD DROP
  nsx iptables -A FORWARD -i in0 -o out0 -s "$gip" -d "$GW" -j ACCEPT
  nsx iptables -P INPUT DROP
  nsx iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  nsx iptables -A FORWARD -i out0 -o in0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || die "FORWARD rules"
  cell_verify "$slot" "$gip" || die "cell $slot did not verify — refusing to report up"
  msg "up: $BR (guest $gip behind $NS, peer $PEER on $WI_BRIDGE, isolated)"
  echo "$BR"
}

# Read every lock back out of the kernel. Installing is not having installed:
# the interesting failures on this box read back correctly and did nothing.
cell_verify() {
  local slot="$1" gip="${2:-}" s
  check_slot "$slot"
  names "$slot"
  ip link show "$BR" >/dev/null 2>&1 || {
    echo "no bridge $BR" >&2
    return 1
  }
  [ "$(cat "/proc/sys/net/ipv4/conf/$BR/arp_ignore" 2>/dev/null)" = 8 ] || {
    echo "$BR arp_ignore != 8" >&2
    return 1
  }
  [ -z "$(ip -4 -o addr show "$BR" 2>/dev/null)" ] || {
    echo "$BR grew an address" >&2
    return 1
  }
  bridge -d link show dev "$VO" 2>/dev/null | grep -q "isolated on" || {
    echo "$VO not isolated" >&2
    return 1
  }
  ip netns pids "$NS" >/dev/null 2>&1 || {
    echo "no netns $NS" >&2
    return 1
  }
  s="$(nsx iptables -S 2>/dev/null)" || return 1
  grep -q -- "-P FORWARD DROP" <<<"$s" || {
    echo "$NS FORWARD policy open" >&2
    return 1
  }
  grep -q -- "-d $GW/32 -i in0 -o out0 -j ACCEPT" <<<"$s" || {
    echo "$NS forward rule missing" >&2
    return 1
  }
  nsx iptables -t nat -S | grep -q -- "-j SNAT" || {
    echo "$NS SNAT missing" >&2
    return 1
  }
  nsx ip neigh show proxy | grep -q "$GW" || {
    echo "$NS pneigh for $GW missing" >&2
    return 1
  }
  if [ -n "$gip" ]; then
    nsx ip route show "$gip/32" | grep -q in0 || {
      echo "$NS host route $gip missing" >&2
      return 1
    }
  fi
  # labhost's backstop covers cell bridges by wildcard; a cell on a box whose
  # walkin-fw predates it would be one lock short, so this is a hard fail.
  iptables -S WALKIN-IN 2>/dev/null | grep -q -- "-i wibr+" ||
    {
      echo "walkin-fw has no wibr+ backstop — re-run provision-walkin-net.sh --apply bridge" >&2
      return 1
    }
  return 0
}

cell_down() {
  local slot="$1" quiet="${2:-}"
  check_slot "$slot"
  names "$slot"
  ip netns del "$NS" 2>/dev/null || true
  ip link del "$VO" 2>/dev/null || true # dies with the ns end normally; belt
  ip link del "$VI" 2>/dev/null || true
  ip link del "$BR" 2>/dev/null || true
  [ -n "$quiet" ] || msg "down: cell $slot removed"
}

cell_prime() {
  local slot="$1" gip="$2" wait="${3:-20}"
  check_slot "$slot"
  check_ip "$gip"
  names "$slot"
  ip netns pids "$NS" >/dev/null 2>&1 || die "no cell for slot $slot — 'up' first"
  nsx python3 - "$GW" "$gip" "$wait" <<'PY' && return 0
import socket, struct, subprocess, sys, time
gw, gip, wait = sys.argv[1], sys.argv[2], float(sys.argv[3])
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0806))
s.bind(("in0", 0)); mac = s.getsockname()[4]
gwb, gipb = socket.inet_aton(gw), socket.inet_aton(gip)
req = (b"\xff" * 6 + mac + struct.pack("!H", 0x0806)
       + struct.pack("!HHBBH", 1, 0x0800, 6, 4, 1) + mac + gwb + b"\x00" * 6 + gipb)
s.settimeout(1.0)
deadline = time.time() + wait
tries = 0
while time.time() < deadline:
    tries += 1
    s.send(req)
    end = min(time.time() + 2.0, deadline + 2.0)
    while time.time() < end:
        try:
            pkt = s.recv(1500)
        except socket.timeout:
            break
        # An ARP REPLY from the guest, addressed to the very MAC it just
        # merged into its cache: the repair, proven.
        if (len(pkt) >= 42 and pkt[12:14] == b"\x08\x06" and pkt[20:22] == b"\x00\x02"
                and pkt[28:32] == gipb and pkt[38:42] == gwb):
            guest_mac = pkt[22:28].hex(":")
            print(f"prime: {gip} answered from {guest_mac} after {tries} attempt(s)")
            # Pin the guest in the namespace so the return path never depends
            # on the guest answering an addressless (0.0.0.0) ARP probe.
            subprocess.run(["ip", "neigh", "replace", gip, "lladdr", guest_mac,
                            "dev", "in0", "nud", "permanent"], check=True)
            sys.exit(0)
sys.exit(1)
PY
  die "$gip never answered the cell's gateway ARP in ${wait}s.
  The three causes, in the order they actually happen:
    1. the guest is PAUSED — a stopped guest processes no frames. Resume it
       under a wake lease first (docs/lab/walkin/NETWORK-PLANE.md).
    2. the tap is not enslaved to this cell's bridge, or is not up.
    3. the guest has not finished waking its stack — retry with a longer wait.
  Deliberately an ERROR: handing over a clone whose first page load will fail
  is the exhibit failure this helper exists to prevent."
}

cell_ls() {
  local link slot
  for link in /sys/class/net/wibr*; do
    [ -e "$link" ] || {
      echo "(no cells)"
      return 0
    }
    slot="${link##*/wibr}"
    names "$slot" 2>/dev/null || continue
    printf '%s  slot %s  peer %s  ns %s  %s\n' "wibr$slot" "$slot" "$PEER" "$NS" \
      "$(cell_verify "$slot" >/dev/null 2>&1 && echo verified || echo BROKEN)"
  done
}

case "${1:-}" in
  up) cell_up "${2:-}" "${3:-}" ;;
  prime)
    wait=20
    [ "${4:-}" = "--wait" ] && wait="${5:-20}"
    cell_prime "${2:-}" "${3:-}" "$wait"
    ;;
  down) cell_down "${2:-}" ;;
  verify) cell_verify "${2:-}" && msg "cell ${2:-} verified" ;;
  ls) cell_ls ;;
  *)
    sed -n '2,60p' "$0" >&2
    exit 2
    ;;
esac
