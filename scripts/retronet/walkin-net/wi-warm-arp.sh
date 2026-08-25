#!/usr/bin/env bash
# wi-warm-arp — repair a fresh clone's STALE ARP entry for the gateway, before
# the visitor ever sees the browser.
#
# THIS IS THE HELPER THE BROKER CALLS. After a clone's tap is up and isolated,
# and before the clone is handed to a visitor:
#
#     /usr/local/sbin/wi-warm-arp <clone-ip> [--wait SECS] [--vmid 952]
#
#   exit 0  the gateway got an ICMP reply from the clone, so the clone has seen
#           the gateway's ARP and its cache now points at CT 952. The clone's
#           first page load will work.
#   exit 1  no reply within --wait. The clone is not ready, or its tap is not on
#           the plane. Report it; do not hand the clone over silently.
#
# WHY IT IS NEEDED — the one real cost of not renumbering. The walk-in plane
# deliberately presents the retronet's own numbering (contract ledger §6/§5.3),
# so a golden restores believing exactly what it believed when it was captured.
# It believes one thing too many: its ARP cache. The golden was captured on
# vmbr-rn, so the guest already holds an entry saying 10.99.0.2 lives at CT
# 951's MAC — an address that does not exist on vmbr-wi. Every first outbound
# flow from every clone is therefore sent to a MAC nothing on this bridge
# answers to, and it is measured, not theoretical: 100% loss from clone to
# gateway until CT 952 pinged the clone, then 0% immediately and permanently
# (lane 8, 2026-08-25). Inbound was fine throughout, because RECEIVING the
# gateway's ARP is exactly what repairs the entry.
#
# So the repair is to make the gateway talk first. A ping from CT 952 to the
# clone forces CT 952 to broadcast an ARP request whose sender fields carry
# 10.99.0.2 and CT 952's real MAC; the clone updates its entry, answers, and is
# fixed for the rest of the session. The ICMP reply is not a side effect — it is
# the proof that the repair landed, which is why this helper pings rather than
# firing a gratuitous ARP into the dark.
#
# A PING ALONE IS NOT ENOUGH, and this is the half that is easy to get wrong.
# Every clone of a station carries its golden's MAC (contract ledger §5.4 —
# loadvm restores it and `mac=` cannot override it), so when a clone is reaped
# and respawned that same MAC turns up on a NEW bridge port. CT 952 is still
# holding a STALE neighbour entry pointing at the port that has gone away, and a
# STALE entry is not a silent one: the kernel UNICASTS its probe to the old
# address, into nothing. No broadcast is ever sent, so the clone never hears the
# gateway and never repairs its own cache.
#
# The symptom is nasty precisely because it is not the first thing you test: the
# FIRST clone primes perfectly and every clone after a reset does not, which
# moves the dead exhibit from the first visitor to the second (lane 1 measured a
# fresh clone 16.9% from pristine with its network dead; with the delete in
# place, 0.003%). So the neighbour entry is deleted FIRST, unconditionally,
# forcing a fresh broadcast ARP that a new port will actually receive.
#
# THE GUEST MUST BE RUNNING to hear any of this. A SIGSTOPped pool member
# processes no frames, so priming a paused clone fails on a plane that is
# working perfectly. The caller resumes it (under a wake lease) before calling;
# this helper fails LOUDLY rather than quietly if it is not running, because a
# silent pass here is a dead browser later.
#
# It belongs here, once, rather than copied into each station's wi-tapnet.sh:
# it is a property of the PLANE (the numbering choice), not of any station, and
# a station that forgot it would fail in a way that looks like a broken exhibit.
#
# Idempotent and cheap: on an already-warm clone the first ping answers at once
# and it returns in well under a second.
set -euo pipefail

WI_VMID="${WI_VMID:-952}"
WI_CT_IF="${WI_CT_IF:-eth0}"
WAIT="${WI_WARM_WAIT:-20}"
IP=""

die() {
  echo "wi-warm-arp: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --wait)
      WAIT="${2:-}"
      shift 2
      ;;
    --vmid)
      WI_VMID="${2:-}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    -*) die "unknown option: $1" ;;
    *)
      [ -z "$IP" ] || die "one clone address at a time (got '$IP' and '$1')"
      IP="$1"
      shift
      ;;
  esac
done

[ -n "$IP" ] || die "usage: wi-warm-arp <clone-ip> [--wait SECS] [--vmid N]"
case "$IP" in
  *[!0-9.]* | '') die "not an IPv4 address: $IP" ;;
esac
[ "$WAIT" -ge 1 ] 2>/dev/null || die "--wait must be a positive integer (got '$WAIT')"
command -v pct >/dev/null 2>&1 || die "no pct — this runs ON labhost (ssh lab '...')"
[ "$(pct status "$WI_VMID" 2>/dev/null)" = "status: running" ] ||
  die "CT $WI_VMID (the walk-in gateway) is not running"

# Drop the gateway's neighbour entry for this address before pinging, so the
# ARP that follows is a BROADCAST rather than a unicast probe to a bridge port
# that no longer exists. Tolerant of there being no entry — that is the happy
# case, not an error.
drop_neigh() {
  pct exec "$WI_VMID" -- ip neigh del "$IP" dev "$WI_CT_IF" >/dev/null 2>&1 || true
}

# One ping per second until one is answered. A clone that has only just been
# resumed may not have its stack up yet, which is why this polls instead of
# firing once and declaring victory. The neighbour entry is dropped before EVERY
# attempt: a failed attempt leaves behind a FAILED/STALE entry of its own, and
# the next ping would probe that instead of broadcasting.
deadline=$((SECONDS + WAIT))
tries=0
while [ "$SECONDS" -lt "$deadline" ]; do
  tries=$((tries + 1))
  drop_neigh
  if pct exec "$WI_VMID" -- ping -c 1 -W 1 -I "$WI_CT_IF" "$IP" >/dev/null 2>&1; then
    echo "wi-warm-arp: $IP answered the gateway after $tries attempt(s) — its ARP entry for the gateway is now correct"
    exit 0
  fi
done
die "$IP never answered the gateway in ${WAIT}s.
  The three causes, in the order they actually happen:
    1. the guest is PAUSED (SIGSTOP) — a stopped guest processes no frames.
       Resume it under a wake lease first; see docs/lab/walkin/NETWORK-PLANE.md.
    2. the tap is not enslaved to the walk-in bridge, or is not up.
    3. the guest has not finished booting its network stack yet — retry with a
       longer --wait.
  This is deliberately an ERROR: handing over a clone whose first page load will
  fail is the exhibit failure this helper exists to prevent."
