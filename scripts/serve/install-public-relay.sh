#!/bin/bash
# install-public-relay.sh — set the edge VPS's UDP DNAT range for the public
# gallery's QUIC video, idempotently and reviewably.
#
# RUNS ON THE EDGE (vm-control), AS ROOT. Not on labhost, not on a station.
# labhost only dials out; the edge is the only place this rule exists.
#
# Why this file exists: labhost's /etc/wireguard/wg0.conf and the old
# docs pointed at "scripts/serve/install-public-relay.sh in Wnt/osgallery" as
# the source of truth. That file was never written (`git log --all` in
# osgallery has no trace of it) and osgallery is now abandoned — kernel-hive
# supersedes it. The edge was therefore configured by hand, nothing could
# review or reproduce it, and the range silently became a cap on the lineup:
# with the edge
# at 54080-54130 and UDP port = 54000+slot, slots 131+ streamed perfectly on the
# LAN and were invisible through the edge (2026-08-09: oricatmos, kc854,
# sinclairql, nextstep).
#
# 2026-08-09: the durable owner of this rule is now the FORWARDER REPO —
# UDP_RELAY_PORT_RANGE in Wnt/forwarder deploy/site.env. Its deploy rewrites
# /etc/nftables.conf from that value on every push to its main, so anything this
# script applies survives only until the next forwarder deploy. This script is
# the emergency hotfix for when that CI path is unavailable; the durable change
# is one commit to site.env (CI redeploys), and the two must be kept equal.
#
# DEFAULT MODE IS A DRY RUN. It prints the rules it matched and the exact nft
# command it would run, and changes nothing. Pass --apply to execute.
#
# Usage, on the edge:
#   ./install-public-relay.sh                      # show current state + planned change
#   ./install-public-relay.sh --apply              # apply, then persist
#   ./install-public-relay.sh --range 54080-54250  # a different range
#   ./install-public-relay.sh --peer 10.66.0.3     # a different relay peer
#   ./install-public-relay.sh --apply --no-persist # runtime only, lost on reboot
set -u

# MUST equal ports.publicRelayLow-publicRelayHigh in registry/registry-v1.json.
# scripts/stations-registry.py asserts these agree, because the failure mode when
# they drift is invisible: every check on labhost stays green.
RELAY_RANGE_DEFAULT="54080-54200"
RELAY_PEER_DEFAULT="10.66.0.3"
NFT_PERSIST="/etc/nftables.conf"

RANGE="$RELAY_RANGE_DEFAULT"
PEER="$RELAY_PEER_DEFAULT"
APPLY=0
PERSIST=1

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --no-persist) PERSIST=0 ;;
    --range)
      RANGE="${2:?--range needs LOW-HIGH}"
      shift
      ;;
    --peer)
      PEER="${2:?--peer needs an IP}"
      shift
      ;;
    -h | --help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
  shift
done

die() {
  echo "install-public-relay: $*" >&2
  exit 1
}

case "$RANGE" in
  [0-9]*-[0-9]*) ;;
  *) die "range must look like LOW-HIGH, got '$RANGE'" ;;
esac
LOW="${RANGE%-*}"
HIGH="${RANGE#*-}"
[ "$LOW" -lt "$HIGH" ] 2>/dev/null || die "range LOW must be below HIGH ($RANGE)"

[ "$(id -u)" = 0 ] || die "must run as root on the edge"
command -v nft >/dev/null 2>&1 || die "nft not found — is this the edge VPS?"

# Refuse to run on the lab box: the rule belongs on the edge, and applying it
# here would look like it worked while changing nothing that matters.
if [ -e /data/vms/streamhost/stations ] || [ -e /etc/forwarder-agent/agent.env ]; then
  die "this looks like the LAB BOX, not the edge. The DNAT rule lives on vm-control."
fi

echo "== current nftables rules mentioning the relay peer or a 540xx port"
CUR="$(nft -a list ruleset 2>/dev/null | grep -nE "$PEER|540[0-9][0-9]" || true)"
if [ -n "$CUR" ]; then
  echo "$CUR"
else
  echo "  (none found — this would be a first install)"
fi
echo

# Find the existing DNAT rule by handle so we replace in place rather than
# stacking a second, overlapping rule on top of it.
HANDLE="$(nft -a list ruleset 2>/dev/null |
  awk -v peer="$PEER" '/dnat/ && $0 ~ peer && /udp/ { for (i = 1; i <= NF; i++) if ($i == "handle") print $(i + 1) }' |
  head -1)"
TABLE="$(nft -a list ruleset 2>/dev/null |
  awk '/^table /{t=$2" "$3} /dnat/ && /udp/ { print t; exit }')"
CHAIN="$(nft -a list ruleset 2>/dev/null |
  awk '/^table /{t=$2" "$3} /^[[:space:]]*chain /{c=$2} /dnat/ && /udp/ { print c; exit }')"

WANT="udp dport $LOW-$HIGH dnat to $PEER"

if [ -n "$HANDLE" ] && [ -n "$TABLE" ] && [ -n "$CHAIN" ]; then
  CMD="nft replace rule $TABLE $CHAIN handle $HANDLE $WANT"
  echo "== planned change (replace the existing rule in place)"
else
  CMD="nft add table ip gallery_relay
nft add chain ip gallery_relay prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'
nft add rule ip gallery_relay prerouting $WANT"
  echo "== planned change (no existing udp dnat rule found — first install)"
fi
printf '  %s\n' "${CMD//$'\n'/$'\n'  }"
echo

if [ "$APPLY" != 1 ]; then
  echo "DRY RUN — nothing changed. Re-run with --apply to execute the above."
  exit 0
fi

echo "== applying"
# shellcheck disable=SC2086  # CMD is one or more deliberate nft invocations
echo "$CMD" | while IFS= read -r line; do
  [ -n "$line" ] || continue
  echo "  + $line"
  eval "$line" || die "failed: $line"
done

echo "== verifying the range is live"
nft list ruleset 2>/dev/null | grep -E "dnat" | grep -q "$LOW-$HIGH" ||
  die "rule did not take: no dnat rule mentions $LOW-$HIGH"
echo "  ok: a dnat rule now covers $LOW-$HIGH -> $PEER"

if [ "$PERSIST" = 1 ]; then
  echo "== persisting to $NFT_PERSIST"
  if [ -f "$NFT_PERSIST" ]; then
    cp -a "$NFT_PERSIST" "$NFT_PERSIST.bak-$(date +%Y%m%d%H%M%S)"
    echo "  backed up $NFT_PERSIST"
  fi
  {
    echo "#!/usr/sbin/nft -f"
    echo "flush ruleset"
    nft list ruleset
  } >"$NFT_PERSIST.new" &&
    mv "$NFT_PERSIST.new" "$NFT_PERSIST" &&
    chmod 0755 "$NFT_PERSIST" ||
    die "could not write $NFT_PERSIST"
  echo "  wrote $NFT_PERSIST (enable with: systemctl enable --now nftables)"
else
  echo "== NOT persisted (--no-persist): this is lost on reboot"
fi

cat <<EOF

Done. The gallery can now reach tiles on UDP $LOW-$HIGH, i.e. registry slots
$((LOW - 54000))-$((HIGH - 54000)).

Verify from the lab box that a previously dark tile now takes a session:
  ssh lab 'journalctl -u streamhost@oricatmos -f'
then open that exhibit in the gallery and watch for SESSION_ACCEPTED.
EOF
