#!/bin/bash
# >>> template-only (rn-onboard.sh strips this block when it renders)
# rn-tapnet.template.sh — the ONE source for every station's link onto the
# retronet bridge vmbr-rn. `scripts/retronet/rn-onboard.sh <id> …` renders it
# into `streamhost/stations/<id>/rn-tapnet.sh`; nothing else should copy a
# sibling station's file by hand again.
#
# Substitution is literal token replacement, so THIS FILE IS ITSELF VALID BASH
# and is linted by the repo's shfmt/shellcheck gate like any other script.
#
# Tokens:
#   @ID@            station id, lowercase        (pcbsd)
#   @IDUPPER@       station id, uppercase        (PCBSD)
#   @TAP@           tap interface name           (pcbsdrn0)
#   @CHAIN@         containment chain name       (PCBSDRN-IN)
#   @ADDRESS@       the guest's retronet address (10.99.0.29)
#   @MAC@           the SCRUBBED placeholder MAC (02:00:00:00:00:1d) — the real
#                   value is read at runtime from the BOX-side local.env
#   @ADDRESSING@    dhcp | static
#   @DOC@           the station's retronet doc path
# Renderer contract: every token must be consumed, and the rendered text is
# re-checked for a real MAC or a non-retronet IP before it is written (rule 1).
# <<< template-only
# rn-tapnet.sh — the @ID@ station's link onto the retronet bridge vmbr-rn.
#
# GENERATED from scripts/retronet/rn-tapnet.template.sh by
# scripts/retronet/rn-onboard.sh. Fix the template, re-render, and land both —
# a hand-edit here is lost the next time any station is onboarded, and the whole
# point of the template is that the plane's containment has ONE definition.
#
# ── What this file is, and what it is NOT ─────────────────────────────────────
#
# It is the BRIDGE-enslaved cousin of streamhost/stations/irix/tapnet.sh. That
# one is a host-only /30 that REFUSES to ever be a bridge port; this is the
# opposite by design — the guest must share L2 with the retronet gateway CT
# (10.99.0.2) so its own stack gets a real DHCP exchange (broadcast UDP),
# working ICMP, and real multi-connection TCP to the gateway's :80 web origin,
# its :5190 OSCAR service and the :4000 legacy ICQ door. slirp can carry none of
# that for a stack that has to DHCP for its own address, and OSCAR cannot
# traverse slirp at all.
#
# A station that ALSO has an x11warp pointer keeps its slirp NIC alongside this
# tap, launched `restrict=on` so it reaches neither labhost nor the outside
# world and only the hostfwd'd X port comes IN. That NIC is a pointer door and
# nothing else; nothing in this file touches it.
#
# ── Containment: four layers, none of them load-bearing alone ────────────────
#
#   1. TOPOLOGY. The tap is enslaved ONLY to vmbr-rn, a bridge with
#      `bridge-ports none` and NO uplink. The guest is never on the LAN's L2.
#   2. ROUTING. The guest's address carries NO default route (Lock 1) — the DHCP
#      reservation withholds option 3, and a statically addressed guest is
#      configured with the on-link route only. Its stack cannot form a packet to
#      anything off 10.99.0.0/24 over this NIC. labhost's `retronet-fw` FORWARD
#      chain (Lock 2) drops any vmbr-rn traffic that tries to route THROUGH the
#      box regardless.
#   3. FILTER. This station's own fail-closed @CHAIN@ (below) lets the guest
#      reach labhost ONLY as the ESTABLISHED reply side of a labhost-initiated
#      connection. Every NEW connection the guest starts toward labhost — the
#      gallery on 10.99.0.1:8443, sshd, anything bound to the bridge address —
#      is DROPPED. Without it the guest could open labhost's 0.0.0.0 listeners
#      by dialling the bridge address, which retronet-fw deliberately leaves
#      reachable (`RETRONET-IN` returns -d 10.99.0.1), and no-default-route does
#      not close that because 10.99.0.1 is ON the guest's own subnet.
#   4. GUEST-SIDE firewall, where the guest has one on by default (PC-BSD's pf
#      is the case that bit: without a scoped pass pair the guest filters its
#      own retronet).
#
# **The chain is hooked into INPUT TWICE — on the guest's source IP and on its
# source MAC.** That is the beos lesson of 2026-08-23: an IP-scoped chain stops
# containing a guest the moment it lands on a pool address instead of its
# reservation, which is exactly what happens when the reservation is in
# local.env but has not been rendered into CT 951 yet. The MAC hook holds
# either way. pcbsd/suse64 and the other early copies carry the IP hook alone;
# this template deliberately does not.
#
# Intra-bridge traffic (guest -> CT 10.99.0.2, for DHCP, DNS, HTTP and OSCAR) is
# pure L2 with bridge-nf-call-iptables=0, so it never touches these chains and
# is always allowed — that is the retronet reaching the retronet, the point.
#
# ── Lifecycle ────────────────────────────────────────────────────────────────
#
# Idempotent, and called `up` from qemu-streamhost.sh on EVERY launch — that is
# what makes it survive a station relaunch and a host reboot without a separate
# systemd unit. The launcher runs under `set -e` and this script exits non-zero
# unless it can read its own rules back OUT of the kernel, so QEMU never starts
# an uncontained guest. The tap is PERSISTENT and is the station's deliverable:
# it is not torn down when the emulator stops (the guard chain then simply
# contains a guest that is not there). `down` is for teardown by hand.
#
# The guard is rebuilt from EMPTY on every `up`, so a temporary hole punched in
# for a bring-up file transfer silently disappears on the next relaunch. The
# symptom is a guest command that hangs forever with no output.
#
#   rn-tapnet.sh up          create + enslave to vmbr-rn + install/verify guard
#   rn-tapnet.sh down        remove guard + unslave + delete the tap
#   rn-tapnet.sh show        current state
#
# Station: @ID@ (@ADDRESSING@ addressing). See @DOC@.
set -u

IF="${RN_TAP_IF:-@TAP@}"
BRIDGE="${RN_TAP_BRIDGE:-vmbr-rn}"
# The guest's reserved address on vmbr-rn. The guard is scoped to it, so the
# filter follows the guest, never the whole bridge.
GUEST_IP="${RN_TAP_GUEST_IP:-@ADDRESS@}"
IN_CHAIN="${RN_TAP_IN_CHAIN:-@CHAIN@}"
# The real MAC is box-local (rule 1): the launcher and this script read the ONE
# line out of the BOX-side /data/kernel-hive/registry/local.env, and the value
# committed here is the scrubbed placeholder. A CT-side copy of local.env is NOT
# the same file and reading it is how a first launch dies.
GUEST_MAC="${RN_TAP_GUEST_MAC:-$(sed -n 's/^[[:space:]]*RN_@IDUPPER@_MAC=//p' /data/kernel-hive/registry/local.env 2>/dev/null | tail -1 | tr -d '\042\047')}"
GUEST_MAC="${GUEST_MAC:-@MAC@}"
# Seconds to wait for the xtables lock. Not optional: a lost race brings the tap
# up with NO fail-closed rules while every message still says "up", which is why
# install_rules is read back by verify_rules.
IPT_WAIT="${RN_TAP_IPT_WAIT:-15}"

msg() { echo "rn-tapnet: $*"; }
die() {
  echo "rn-tapnet: $*" >&2
  exit 1
}

# Fail-closed filter, rebuilt from empty on each call.
install_rules() {
  iptables -w "$IPT_WAIT" -N "$IN_CHAIN" 2>/dev/null || true
  iptables -w "$IPT_WAIT" -F "$IN_CHAIN"
  # replies to something labhost dialled (the guest never starts these).
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # everything else the guest initiates toward labhost is refused.
  iptables -w "$IPT_WAIT" -A "$IN_CHAIN" -j DROP
  # Hook the guest into INPUT ABOVE retronet-fw's RETRONET-IN so the scoped DROP
  # wins over its blanket `-d 10.99.0.1 -j RETURN`. Re-inserted at 1 on every
  # launch, which keeps it above the boot-time RETRONET-IN. Two hooks, IP and
  # MAC — see the header.
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
  # IFNAMSIZ is 16 including the NUL, and both the kernel and MAME's
  # MAME_TAP_IFNAME path TRUNCATE silently — an over-long name is a collision
  # waiting to happen, not a cosmetic problem.
  [ "${#IF}" -le 15 ] || die "interface name longer than 15 chars: $IF"
  [ "${#IN_CHAIN}" -le 28 ] || die "chain name longer than 28 chars: $IN_CHAIN"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge $BRIDGE is absent (the gateway provisioner makes it)"
  # PERSISTENT tap: it exists before the emulator starts and survives it exiting,
  # so the link is not a function of process lifetime. QEMU attaches with
  # -netdev tap,ifname=$IF,script=no,downscript=no (it opens an EXISTING tap);
  # MAME opens it through MAME_TAP_IFNAME and never creates one.
  if ! ip link show "$IF" >/dev/null 2>&1; then
    ip tuntap add dev "$IF" mode tap || die "could not create tap $IF"
    msg "created tap $IF"
  fi
  # Enslave to the retronet bridge — the whole point of this variant. Idempotent:
  # `master` is a no-op if already set to $BRIDGE, and re-homes if it drifted.
  local cur
  cur="$(cat "/sys/class/net/$IF/master/ifindex" 2>/dev/null || echo '')"
  if [ "$(cat "/sys/class/net/$BRIDGE/ifindex" 2>/dev/null || echo x)" != "$cur" ]; then
    ip link set dev "$IF" master "$BRIDGE" || die "could not enslave $IF to $BRIDGE"
  fi
  # No L3 address on the tap: it is a pure bridge port. labhost reaches the guest
  # via the bridge's own 10.99.0.1. IPv6 off on the port for good measure
  # (retronet-fw drops vmbr-rn IPv6 anyway).
  sysctl -qw "net.ipv6.conf.$IF.disable_ipv6=1" 2>/dev/null || true
  ip link set dev "$IF" up
  install_rules
  if ! verify_rules; then
    install_rules # one retry: the usual cause is a lost xtables race, not a bad rule
    verify_rules || die "guest containment rules for $IF did not verify — refusing to report up"
  fi
  msg "up: $IF enslaved to $BRIDGE; guest $GUEST_IP/$GUEST_MAC contained (NEW->labhost dropped)"
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
  echo "carrier=$(cat "/sys/class/net/$IF/carrier" 2>/dev/null || echo '?')"
  echo "disable_ipv6=$(cat "/proc/sys/net/ipv6/conf/$IF/disable_ipv6" 2>/dev/null || echo '?')"
  echo "guest_mac=$GUEST_MAC"
  iptables -w "$IPT_WAIT" -S "$IN_CHAIN" 2>/dev/null || echo "(no $IN_CHAIN)"
  iptables -w "$IPT_WAIT" -S INPUT | grep -- "$IN_CHAIN" || echo "(INPUT not hooked)"
}

case "${1:-}" in
  up) do_up ;;
  down) do_down ;;
  show) do_show ;;
  *)
    # The usage block, wherever the header prose has pushed it to.
    sed -n '/^#   rn-tapnet.sh up/,/^# Station:/p' "$0" >&2
    exit 2
    ;;
esac
