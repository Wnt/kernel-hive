#!/bin/bash
# rn-tapnet.sh — the ubuntu station's link onto the retronet bridge vmbr-rn.
#
# The Ubuntu 4.10 sibling of streamhost/stations/beos/rn-tapnet.sh (and, before
# it, win98se/ and solaris/). Those proved the host-side pattern — a persistent
# tap enslaved to vmbr-rn plus a fail-closed per-guest containment chain — and
# this is the same wiring for the Warty live-CD guest, which joined the retronet
# on 2026-09-03 so that Firefox 0.9 can reach the gateway's :80 corpus origin and
# Gaim 1.0 can sign in to the OSCAR gateway, both over real L2.
# See docs/lab/retronet/STATION-ubuntu.md.
#
# Containment is layered and does NOT depend on any one thing:
#
#   1. TOPOLOGY. The tap is enslaved ONLY to vmbr-rn, a bridge with
#      `bridge-ports none` and NO uplink. The guest is never on the LAN's L2.
#   2. ROUTING. The guest has NO default route (Lock 1). It is a DHCP client and
#      retronet-dhcp deliberately withholds option 3 (router), so the lease
#      carries an IP + mask + DNS and nothing to route through: the 2.6.8 stack
#      cannot form a packet to anything off 10.99.0.0/24. labhost's `retronet-fw`
#      FORWARD chain (Lock 2) drops any vmbr-rn traffic that tries to route
#      THROUGH the box regardless.
#   3. FILTER. This station's own fail-closed INPUT chain (below), scoped to the
#      guest's source IP AND its source MAC, lets the guest reach labhost ONLY as
#      the ESTABLISHED reply side of a labhost-initiated connection. Every NEW
#      connection the guest starts toward labhost — the gallery on
#      10.99.0.1:8443, sshd, anything bound to the bridge address — is DROPPED.
#
# ubuntu has NO exec channel at all (`exec_kind: none`; it is a live CD driven by
# QMP keys/mouse and read off the framebuffer), so the guest never legitimately
# initiates a flow toward labhost: the chain is a pure fail-closed wall and the
# ESTABLISHED,RELATED RETURN is only there to keep the shape uniform with the
# rest of the fleet. Intra-bridge traffic (guest -> CT 10.99.0.2, for DHCP, DNS,
# the :80 corpus origin and OSCAR :5190) is pure L2 with
# bridge-nf-call-iptables=0, so it never touches these chains and is always
# allowed — the retronet reaching the retronet.
#
# Idempotent, and called `up` from qemu-streamhost.sh on EVERY launch — that is
# what makes it survive a station relaunch and a host reboot without a separate
# systemd unit. The tap is PERSISTENT: it is not torn down when QEMU stops (the
# guard chain then simply contains a guest that is not there). `down` is for
# teardown by hand.
#
#   rn-tapnet.sh up          create + enslave to vmbr-rn + install/verify guard
#   rn-tapnet.sh down        remove guard + unslave + delete the tap
#   rn-tapnet.sh show        current state
set -u

IF="${RN_TAP_IF:-ubunturn0}"
BRIDGE="${RN_TAP_BRIDGE:-vmbr-rn}"
# The guest's address on vmbr-rn: DHCP, but RESERVED for this station's MAC by
# retronet-dhcp, so it is stable. The guard chain is scoped to it, so the filter
# follows the guest, never the whole bridge.
GUEST_IP="${RN_TAP_GUEST_IP:-10.99.0.30}"
IN_CHAIN="UBUNTURN-IN"
# The guest's unique MAC on vmbr-rn -- the SECOND thing the guard chain is scoped
# to: an IP-scoped chain contains the guest only for as long as the guest keeps
# the address we expect, and a DHCP client that fails to match its reservation
# lands on a pool address and walks straight out of an -s rule (beos demonstrated
# exactly that on 2026-08-23). The MAC is the station's stable identity. Real
# value is box-local in registry/local.env RN_UBUNTU_MAC, exactly as the launcher
# reads it; the committed fallback is the scrubbed placeholder.
GUEST_MAC="${RN_TAP_GUEST_MAC:-$(sed -n 's/^[[:space:]]*RN_UBUNTU_MAC=//p' /data/kernel-hive/registry/local.env 2>/dev/null | tail -1 | tr -d '\042\047')}"
GUEST_MAC="${GUEST_MAC:-02:00:00:00:00:1e}"
# Seconds to wait for the xtables lock (see win98se/rn-tapnet.sh for why this is
# not optional): a lost race brings the tap up with NO fail-closed rules while
# every message still says "up", which is why install_rules is read back by
# verify_rules.
IPT_WAIT="${RN_TAP_IPT_WAIT:-15}"

msg() { echo "rn-tapnet: $*"; }
die() {
  echo "rn-tapnet: $*" >&2
  exit 1
}

# Fail-closed filter: every NEW flow the guest starts toward labhost is dropped;
# only the reply side of a labhost-initiated connection passes. Rebuilt from
# empty each call.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # everything else the guest initiates toward labhost — gallery :8443, ssh :22,
  # any 0.0.0.0 listener reachable via the bridge address — is refused.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # Hook the guest into INPUT, ABOVE retronet-fw's RETRONET-IN so the scoped DROP
  # wins over its blanket `-d 10.99.0.1 -j RETURN`. Re-inserted at 1 on every
  # launch, which keeps it above the boot-time RETRONET-IN. Two hooks: IP and
  # MAC (see GUEST_MAC above).
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN" 2>/dev/null; do :; done
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -m mac --mac-source "$GUEST_MAC" -j "$IN_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -I INPUT 1 -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN"
  iptables -w "$IPT_WAIT" -I INPUT 1 -i "$BRIDGE" -m mac --mac-source "$GUEST_MAC" -j "$IN_CHAIN"
}

# Read the isolation back out of the kernel: install_rules cannot be trusted to
# have worked just because it ran (lock contention, a ruleset reload underneath).
verify_rules() {
  local s
  s="$(iptables -w "$IPT_WAIT" -S 2>/dev/null)" || return 1
  grep -qx -- "-A INPUT -s $GUEST_IP/32 -i $BRIDGE -j $IN_CHAIN" <<<"$s" || return 1
  grep -qix -- "-A INPUT -i $BRIDGE -m mac --mac-source $GUEST_MAC -j $IN_CHAIN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" <<<"$s" || return 1
  grep -qx -- "-A $IN_CHAIN -j DROP" <<<"$s" || return 1
}

remove_rules() {
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -s "$GUEST_IP" -j "$IN_CHAIN" 2>/dev/null; do :; done
  while iptables -w "$IPT_WAIT" -D INPUT -i "$BRIDGE" -m mac --mac-source "$GUEST_MAC" -j "$IN_CHAIN" 2>/dev/null; do :; done
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -X "$IN_CHAIN" 2>/dev/null || true
}

do_up() {
  [ "$(id -u)" = 0 ] || die "must run as root"
  case "$IF" in
    *[!a-zA-Z0-9_-]* | '') die "invalid interface name: $IF" ;;
  esac
  [ "${#IF}" -le 15 ] || die "interface name longer than 15 chars: $IF"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE is absent (the gateway provisioner creates it)"
  # PERSISTENT tap: it exists before QEMU starts and survives QEMU exiting, so
  # the link is not a function of process lifetime. QEMU attaches with
  # -netdev tap,ifname=$IF,script=no,downscript=no (it opens an EXISTING tap).
  if ! ip link show "$IF" >/dev/null 2>&1; then
    ip tuntap add dev "$IF" mode tap || die "could not create tap $IF"
    msg "created tap $IF"
  fi
  # Enslave to the retronet bridge. Idempotent: `master` is a no-op if already
  # set to $BRIDGE, and re-homes if it drifted.
  local cur
  cur="$(cat "/sys/class/net/$IF/master/ifindex" 2>/dev/null || echo '')"
  if [ "$(cat "/sys/class/net/$BRIDGE/ifindex" 2>/dev/null || echo x)" != "$cur" ]; then
    ip link set dev "$IF" master "$BRIDGE" || die "could not enslave $IF to $BRIDGE"
  fi
  # No L3 address on the tap: it is a pure bridge port. IPv6 off on the port for
  # good measure (retronet-fw drops vmbr-rn IPv6 anyway).
  sysctl -qw "net.ipv6.conf.$IF.disable_ipv6=1" 2>/dev/null || true
  ip link set dev "$IF" up
  install_rules
  if ! verify_rules; then
    install_rules # one retry: the usual cause is a lost xtables race, not a bad rule
    verify_rules || die "guest containment rules for $IF did not verify — refusing to report up"
  fi
  msg "up: $IF enslaved to $BRIDGE; guest $GUEST_IP contained (NEW->labhost dropped)"
}

do_down() {
  [ "$(id -u)" = 0 ] || die "must run as root"
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
  echo "disable_ipv6=$(cat "/proc/sys/net/ipv6/conf/$IF/disable_ipv6" 2>/dev/null || echo '?')"
  iptables -w "$IPT_WAIT" -S "$IN_CHAIN" 2>/dev/null || echo "(no $IN_CHAIN)"
  echo "guest_mac=$GUEST_MAC"
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
