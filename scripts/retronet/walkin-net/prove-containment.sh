#!/usr/bin/env bash
# prove-containment.sh — stand up two throwaway "clones" on vmbr-wi and
# DEMONSTRATE, from the outside, that the walk-in plane does what it claims.
#
#   ssh lab '/data/kernel-hive/scripts/retronet/walkin-net/prove-containment.sh'
#
# Containment is proven, never assumed. A rule that is present is not a rule that
# works: the interesting failures on this box have all been rules that read back
# correctly and did nothing (a lost xtables race, br_netfilter changing which
# hook sees a frame, a bridge driver too old for a port flag). So this script
# does not inspect the ruleset. It creates two network namespaces, gives each a
# veth whose host end is an isolated walk-in tap, addresses them the way a clone
# is addressed — statically, from its golden — and then TRIES the things a clone
# must not be able to do.
#
# It is safe to run while real clones are on the plane: the two proof addresses
# are outside every station's baked address, and the taps are named for this
# script. It tears everything down at the end, always — teardown is part of
# "done".
#
# Every check prints the command's own output. A check that must fail is
# reported as PASS when it fails, and the script exits non-zero if ANY check
# comes out the wrong way.
set -uo pipefail

WI_BRIDGE="${WI_BRIDGE:-vmbr-wi}"
WI_GATEWAY_IP="${WI_GATEWAY_IP:-10.99.0.2}"
WI_PREFIX="${WI_PREFIX:-24}"
# The walk-in plane presents the RETRONET's numbering on a different L2 (contract
# ledger §6). So "the fleet" is a set of addresses that exist on BOTH planes, and
# the proof is that on this one they answer from nowhere: 10.99.0.1 is labhost's
# retronet address and 10.99.0.24/.25 are live stations (irix, nextstep).
RN_HOST_IP="${RN_HOST_IP:-10.99.0.1}"
RN_STATION_A="${RN_STATION_A:-10.99.0.24}"
RN_STATION_B="${RN_STATION_B:-10.99.0.25}"
# Deliberately NOT a station's baked address: real clones may be on the plane.
IP_A="${IP_A:-10.99.0.240}"
IP_B="${IP_B:-10.99.0.241}"
# A real public address, to prove there is no internet. Not lab-identifying.
WAN_IP="${WAN_IP:-1.1.1.1}"
# labhost's LAN address is read from the kernel at runtime and never written
# down: it is a real address, and real addresses do not go in this repo.
LAN_IP="$(ip -4 -o addr show "${WI_LAN_IF:-vmbr0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"

NS_A="wi-proof-a"
NS_B="wi-proof-b"
TAP_A="wi-proof-a0"
TAP_B="wi-proof-b0"
IN_IF="wi0"

PASS=0
FAIL=0

hdr() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() {
  PASS=$((PASS + 1))
  printf '   \033[32mPASS\033[0m  %s\n' "$*"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '   \033[31mFAIL\033[0m  %s\n' "$*"
}
die() {
  printf 'prove-containment: %s\n' "$*" >&2
  exit 1
}

nsx() {
  local ns="$1"
  shift
  ip netns exec "$ns" "$@"
}

# A check that must SUCCEED.
must() {
  local label="$1" ns="$2"
  shift 2
  local out rc
  out="$(nsx "$ns" "$@" 2>&1)"
  rc=$?
  if [ $rc -eq 0 ]; then ok "$label"; else bad "$label  (rc=$rc)"; fi
  printf '         $ %s\n' "$*"
  printf '%s\n' "$out" | sed 's/^/         | /' | head -6
}

# A check that must FAIL. This is the whole point of the script, so it prints
# the attempt AND its output — "it timed out" and "it was refused" are both
# containment, and "it answered" is the bug.
mustnot() {
  local label="$1" ns="$2"
  shift 2
  local out rc
  out="$(nsx "$ns" "$@" 2>&1)"
  rc=$?
  if [ $rc -ne 0 ]; then ok "$label — refused"; else bad "$label — REACHABLE, containment is broken"; fi
  printf '         $ %s   (rc=%s)\n' "$*" "$rc"
  printf '%s\n' "$out" | sed 's/^/         | /' | head -6
}

cleanup() {
  local ns tap
  for ns in "$NS_A" "$NS_B"; do
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
  for tap in "$TAP_A" "$TAP_B"; do
    ip link del "$tap" 2>/dev/null || true
  done
}

make_clone() {
  local ns="$1" tap="$2" ip="$3"
  ip netns del "$ns" 2>/dev/null || true
  ip link del "$tap" 2>/dev/null || true
  ip netns add "$ns" || die "netns add $ns"
  # `ip netns exec` bind-mounts /etc/netns/<ns>/* over /etc/*, so this
  # resolv.conf lands in the namespace and NEVER touches labhost's.
  install -d -m 0755 "/etc/netns/$ns"
  printf 'nameserver %s\n' "$WI_GATEWAY_IP" >"/etc/netns/$ns/resolv.conf"
  ip link add "$tap" type veth peer name "$IN_IF" || die "veth $tap"
  ip link set "$IN_IF" netns "$ns"
  ip link set "$tap" master "$WI_BRIDGE" || die "enslave $tap to $WI_BRIDGE"
  ip link set "$tap" up
  nsx "$ns" ip link set lo up
  # Static, and NO default route — exactly what a golden restores with. There is
  # no DHCP on this plane (contract ledger §6): each clone keeps the address it
  # was captured with.
  nsx "$ns" ip addr add "$ip/$WI_PREFIX" dev "$IN_IF"
  nsx "$ns" ip link set "$IN_IF" up
  # The helper lanes 7/8/10 call, used here exactly as they will use it.
  /usr/local/sbin/wi-isolate on "$tap" >/dev/null || die "wi-isolate on $tap"
}

trap cleanup EXIT

[ "$(id -u)" = 0 ] || die "must run as root on labhost"
ip link show "$WI_BRIDGE" >/dev/null 2>&1 || die "$WI_BRIDGE absent — run provision-walkin-net.sh --apply first"
[ -n "$LAN_IP" ] || die "could not read labhost's LAN address from ${WI_LAN_IF:-vmbr0}"

hdr "stand up two clones on $WI_BRIDGE (isolated ports, static addresses, no default route)"
make_clone "$NS_A" "$TAP_A" "$IP_A"
make_clone "$NS_B" "$TAP_B" "$IP_B"
printf '   clone A %-12s %s (tap %s)\n' "$NS_A" "$IP_A" "$TAP_A"
printf '   clone B %-12s %s (tap %s)\n' "$NS_B" "$IP_B" "$TAP_B"
/usr/local/sbin/wi-isolate show
if [ -z "$(nsx "$NS_A" ip route show default)" ]; then
  ok "clone A has NO default route — nothing to route through, by construction"
else
  bad "clone A HAS a default route: $(nsx "$NS_A" ip route show default)"
fi
# The plane's own priming helper, exercised the way the broker will call it.
if /usr/local/sbin/wi-warm-arp "$IP_A" --wait 15 >/dev/null 2>&1; then
  ok "wi-warm-arp primed clone A (the gateway spoke first)"
else
  bad "wi-warm-arp could not prime clone A"
fi

hdr "it MUST reach the corpus web on $WI_GATEWAY_IP"
must "ping the walk-in gateway" "$NS_A" ping -c2 -W2 "$WI_GATEWAY_IP"
must "DNS: any name resolves to the gateway" "$NS_A" dig +short +time=3 +tries=1 "@$WI_GATEWAY_IP" spacejam.com
must "origin :80 (seamless, no proxy)" "$NS_A" curl -s -S -o /dev/null -w 'HTTP %{http_code}\n' --max-time 10 http://example.museum/
must "proxy :3128" "$NS_A" curl -s -S -o /dev/null -w 'HTTP %{http_code}\n' --max-time 10 -x "$WI_GATEWAY_IP:3128" http://example.museum/

# A REAL RENDER, not a port check. The proxy answers 200 for search.retronet
# whether the backend is up or not — when it is down it substitutes a period
# "Search Is Offline" page, which is exactly how this plane shipped broken once.
hdr "search.retronet MUST actually search"
hits=""
for door in "origin" "proxy"; do
  case "$door" in
    origin) body="$(nsx "$NS_A" curl -s --max-time 15 'http://search.retronet/search?q=web' 2>&1)" ;;
    proxy) body="$(nsx "$NS_A" curl -s --max-time 15 -x "$WI_GATEWAY_IP:3128" 'http://search.retronet/search?q=web' 2>&1)" ;;
  esac
  # Herestrings, not pipes. `set -o pipefail` plus `grep -q` is a trap: grep
  # exits the moment it matches, the writer takes SIGPIPE, and the PIPELINE
  # reports 141 — so a successful match reads as a failed test. It cost two runs
  # of this script to notice, because the failing branch printed the very
  # evidence that proved the match.
  hits="$(grep -coiE 'href="http://[a-z0-9.-]+' <<<"$body" || true)"
  if grep -qi "Search Is Offline" <<<"$body"; then
    bad "search via $door — the backend is DOWN (the proxy served its offline page)"
  elif grep -qi '<title>AltaVista:' <<<"$body" && [ "$hits" -gt 0 ]; then
    ok "search via $door rendered an AltaVista results page with $hits corpus link(s)"
  else
    bad "search via $door returned no recognisable result page"
  fi
  # The evidence is a RENDER, not a status code: the page's own title and a
  # result it found in the corpus.
  grep -oiE '<title>[^<]*</title>' <<<"$body" | head -1 | sed 's/^/         | /'
  grep -oiE 'href="http://[a-z0-9./?=&_%~-]+"' <<<"$body" | head -2 | sed 's/^/         | /'
done

hdr "it MUST NOT reach the fleet — the SAME numbering, a different L2"
mustnot "labhost's retronet address $RN_HOST_IP" "$NS_A" ping -c2 -W2 "$RN_HOST_IP"
mustnot "a live station, irix $RN_STATION_A" "$NS_A" ping -c2 -W2 "$RN_STATION_A"
mustnot "a live station, nextstep $RN_STATION_B" "$NS_A" ping -c2 -W2 "$RN_STATION_B"
mustnot "the retronet gateway's own web, if it were reachable" "$NS_A" curl -s -S -o /dev/null --max-time 5 "http://$RN_HOST_IP/"

hdr "the walk-in gateway MUST NOT serve the fleet's services"
mustnot "OSCAR 5190 (the station-to-station chat relay)" "$NS_A" nc -z -w 3 "$WI_GATEWAY_IP" 5190
mustnot "OSCAR slirp door 5191" "$NS_A" nc -z -w 3 "$WI_GATEWAY_IP" 5191
mustnot "TOC 9898" "$NS_A" nc -z -w 3 "$WI_GATEWAY_IP" 9898
mustnot "sshd 22" "$NS_A" nc -z -w 3 "$WI_GATEWAY_IP" 22
mustnot "the search backend, which is CT-loopback only" "$NS_A" nc -z -w 3 "$WI_GATEWAY_IP" 8090

hdr "it MUST NOT reach labhost"
mustnot "labhost's LAN address (read at runtime, never committed)" "$NS_A" ping -c2 -W2 "$LAN_IP"
mustnot "the gallery on labhost:8443" "$NS_A" nc -z -w 3 "$LAN_IP" 8443
mustnot "sshd on labhost:22" "$NS_A" nc -z -w 3 "$LAN_IP" 22

hdr "it MUST NOT reach the internet"
mustnot "ping $WAN_IP" "$NS_A" ping -c2 -W2 "$WAN_IP"
mustnot "http to $WAN_IP" "$NS_A" curl -s -S -o /dev/null --max-time 5 "http://$WAN_IP/"
mustnot "real DNS resolution off-box" "$NS_A" dig +short +time=3 +tries=1 "@$WAN_IP" example.com

hdr "it MUST NOT reach another clone (kernel-enforced port isolation)"
mustnot "clone A -> clone B ($IP_B)" "$NS_A" ping -c2 -W2 "$IP_B"
mustnot "clone B -> clone A ($IP_A)" "$NS_B" ping -c2 -W2 "$IP_A"
mustnot "clone A -> clone B, TCP" "$NS_A" nc -z -w 3 "$IP_B" 80
must "clone B still reaches the gateway (isolation is not an outage)" "$NS_B" ping -c2 -W2 "$WI_GATEWAY_IP"

# These run from LABHOST, not from a namespace — and from labhost, 10.99.0.2
# routes over vmbr-rn to CT 951, because labhost holds no address on vmbr-wi.
# The same literal address therefore means "the walk-in gateway" inside a clone
# and "the retronet gateway" out here, which is the whole trick of this plane and
# also the easiest way to test the wrong machine by accident.
hdr "the LIVE retronet is unharmed (this plane never touches CT 951)"
if [ "$(pct config 951 | grep -c '^net')" = 1 ]; then ok "CT 951 is still single-homed"; else bad "CT 951 grew an interface"; fi
if nc -z -w 3 "$WI_GATEWAY_IP" 5190; then ok "retronet OSCAR 5190 answers from labhost"; else bad "retronet OSCAR 5190 DOWN"; fi
if curl -s -o /dev/null --max-time 5 "http://$WI_GATEWAY_IP/"; then ok "retronet corpus origin answers from labhost"; else bad "retronet corpus origin DOWN"; fi
if dig +short +time=3 +tries=1 "@$WI_GATEWAY_IP" anything.test | grep -q "$WI_GATEWAY_IP"; then
  ok "retronet wildcard DNS answers from labhost"
else bad "retronet wildcard DNS DOWN"; fi

hdr "result"
printf '   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
echo "   walk-in plane contained: corpus web only."
