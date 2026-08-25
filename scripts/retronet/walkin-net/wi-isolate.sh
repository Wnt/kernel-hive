#!/usr/bin/env bash
# wi-isolate — put one walk-in tap into the bridge's private-VLAN mode, and
# prove the kernel took it.
#
# THIS IS THE HELPER LANES 7/8/10 CALL. A station's own wi-tapnet.sh creates its
# tap and enslaves it to vmbr-wi, exactly the way its rn-tapnet.sh sibling does
# for vmbr-rn; then it calls, as the last step of `up`:
#
#     /usr/local/sbin/wi-isolate on "$IF"      # or, from a repo checkout:
#     "$(dirname …)/../../../scripts/retronet/walkin-net/wi-isolate.sh" on "$IF"
#
# and `down` needs nothing — deleting the tap takes its port flags with it.
#
# WHY IT EXISTS AS A SHARED TOOL rather than one more copied fragment. Every
# other part of a station's netdev is per-station on purpose. This one is not a
# station property at all: it is a property of the BRIDGE, it is a single flag,
# and forgetting it does not break the station that forgot — it silently opens
# every OTHER clone to it. A Linux bridge switches between its own ports, so
# two clones on vmbr-wi can talk to each other by default, and on this box
# bridge-nf-call-iptables is 0, so no iptables rule anywhere will ever see that
# traffic. `isolated on` is a kernel-enforced private VLAN: an isolated port may
# exchange frames only with NON-isolated ports of the same bridge. The gateway
# CT's port is the only one left un-isolated, which is precisely the topology
# the walk-in plane wants — every clone reaches the gateway, no clone reaches a
# clone.
#
# Fail-closed: `on` refuses unless the tap is a port of $WI_BRIDGE, and it reads
# the flag back out of the kernel before reporting success.
#
#   wi-isolate on <tap>        isolate a clone tap (idempotent)
#   wi-isolate off <tap>       un-isolate — TEARDOWN/DEBUG ONLY, never a clone
#   wi-isolate gateway <port>  assert the gateway port is NOT isolated
#   wi-isolate verify <tap>    exit 0 iff <tap> is isolated on $WI_BRIDGE
#   wi-isolate show            every port of $WI_BRIDGE and its isolation state
set -euo pipefail

BRIDGE="${WI_BRIDGE:-vmbr-wi}"

die() {
  echo "wi-isolate: $*" >&2
  exit 1
}

need_port() {
  local tap="$1" master
  ip link show "$tap" >/dev/null 2>&1 || die "no such interface: $tap"
  master="$(basename "$(readlink "/sys/class/net/$tap/master" 2>/dev/null || echo none)")"
  [ "$master" = "$BRIDGE" ] || die "$tap is enslaved to '$master', not $BRIDGE — isolate the tap AFTER enslaving it"
}

# Read the flag back out of the kernel. `bridge -j -d link show` is the only
# honest source: the command that sets it succeeds even when the bridge driver
# is too old to have the flag, in which case nothing is isolated and nothing
# says so.
is_isolated() {
  local tap="$1" v
  v="$(bridge -j -d link show dev "$tap" 2>/dev/null | jq -r '.[0].isolated // "missing"')"
  [ "$v" = "true" ]
}

do_on() {
  local tap="$1"
  need_port "$tap"
  bridge link set dev "$tap" isolated on || die "could not set isolated on $tap"
  is_isolated "$tap" ||
    die "isolation did not read back on $tap — clone<->clone is OPEN; refusing to report success"
  echo "wi-isolate: $tap isolated on $BRIDGE (reaches the gateway port only)"
}

do_off() {
  local tap="$1"
  need_port "$tap"
  bridge link set dev "$tap" isolated off || die "could not clear isolated on $tap"
  echo "wi-isolate: $tap NO LONGER isolated on $BRIDGE"
}

# The gateway's own port must stay un-isolated: two isolated ports cannot talk,
# so an isolated gateway port would take the corpus web away from every clone
# at once, with no rule anywhere to blame.
do_gateway() {
  local port="$1"
  need_port "$port"
  if is_isolated "$port"; then
    die "gateway port $port is ISOLATED — no clone can reach the gateway; run: bridge link set dev $port isolated off"
  fi
  echo "wi-isolate: gateway port $port is un-isolated (correct)"
}

do_show() {
  local p iso
  echo "bridge $BRIDGE:"
  for p in $(ls "/sys/class/net/$BRIDGE/brif" 2>/dev/null || true); do
    iso="$(bridge -j -d link show dev "$p" 2>/dev/null | jq -r '.[0].isolated // "missing"')"
    printf '  %-16s isolated=%s\n' "$p" "$iso"
  done
}

cmd="${1:-show}"
case "$cmd" in
  on | off | gateway | verify)
    [ $# -ge 2 ] || die "usage: wi-isolate $cmd <interface>"
    case "$cmd" in
      on) do_on "$2" ;;
      off) do_off "$2" ;;
      gateway) do_gateway "$2" ;;
      verify)
        need_port "$2"
        is_isolated "$2" || die "$2 is NOT isolated"
        echo "wi-isolate: $2 isolated"
        ;;
    esac
    ;;
  show) do_show ;;
  *)
    sed -n '2,30p' "$0" >&2
    exit 2
    ;;
esac
