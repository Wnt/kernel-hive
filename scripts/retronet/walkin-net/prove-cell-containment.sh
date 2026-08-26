#!/usr/bin/env bash
# prove-cell-containment.sh — stand up two walk-in CELLS whose "guests" are
# IDENTICAL ON THE WIRE — same MAC, same baked IP, the loadvm constraint
# mimicked exactly — and DEMONSTRATE that the multi-clone plane does what it
# claims (contract ledger §5.4/§6):
#
#   ssh lab '/data/kernel-hive/scripts/retronet/walkin-net/prove-cell-containment.sh'
#
# The sibling of prove-containment.sh, which proves the flat plane the cells
# stand on and still runs unchanged. This one proves the layer wi-clonecell
# adds: that two identical machines both reach the corpus web CONCURRENTLY as
# distinct gateway peers, and that neither can reach anything else — the fleet,
# labhost, the internet, the other cell's guest OR its NAT peer. It inspects no
# rules: it builds the cells with the real helper, primes them down the real
# path (a seeded stale ARP entry for the gateway, repaired by `wi-clonecell
# prime`), and then TRIES everything a clone must not be able to do.
#
# Safe to run while real clones are on the plane: the proof guest address
# (10.99.0.239) is outside every station's baked address, and the proof slots
# are taken from the top of the range, clear of the broker's low-first
# allocation. It tears everything down at the end, always.
set -uo pipefail

WI_BRIDGE="${WI_BRIDGE:-vmbr-wi}"
GW="${WI_GATEWAY_IP:-10.99.0.2}"
CLONECELL="${WI_CLONECELL:-/usr/local/sbin/wi-clonecell}"
SLOT_A="${SLOT_A:-198}"
SLOT_B="${SLOT_B:-199}"
GIP="${GIP:-10.99.0.239}"         # ONE address for BOTH guests — the point
GMAC="${GMAC:-02:00:00:00:57:ef}" # ONE MAC for BOTH guests — the point
STALE_MAC="02:de:ad:be:ef:51"     # stands in for CT 951's MAC in the warm cache
RN_HOST_IP="${RN_HOST_IP:-10.99.0.1}"
RN_STATION="${RN_STATION:-10.99.0.24}"
WAN_IP="${WAN_IP:-1.1.1.1}"
LAN_IP="$(ip -4 -o addr show "${WI_LAN_IF:-vmbr0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
PEER_A="10.99.0.$((SLOT_A - 100))"
PEER_B="10.99.0.$((SLOT_B - 100))"
NS_A="wi-cellproof-a"
NS_B="wi-cellproof-b"

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
  printf 'prove-cell-containment: %s\n' "$*" >&2
  exit 1
}
nsx() {
  local ns="$1"
  shift
  ip netns exec "$ns" "$@"
}

must() {
  local label="$1" ns="$2"
  shift 2
  local out rc
  out="$(nsx "$ns" "$@" 2>&1)"
  rc=$?
  if [ $rc -eq 0 ]; then ok "$label"; else bad "$label  (rc=$rc)"; fi
  printf '         $ %s\n' "$*"
  printf '%s\n' "$out" | sed 's/^/         | /' | head -5
}
mustnot() {
  local label="$1" ns="$2"
  shift 2
  local out rc
  out="$(nsx "$ns" "$@" 2>&1)"
  rc=$?
  if [ $rc -ne 0 ]; then ok "$label — refused"; else bad "$label — REACHABLE, containment is broken"; fi
  printf '         $ %s   (rc=%s)\n' "$*" "$rc"
  printf '%s\n' "$out" | sed 's/^/         | /' | head -5
}

cleanup() {
  local ns
  for ns in "$NS_A" "$NS_B"; do
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
  ip link del wi-cellpf-a0 2>/dev/null || true
  ip link del wi-cellpf-b0 2>/dev/null || true
  "$CLONECELL" down "$SLOT_A" >/dev/null 2>&1 || true
  "$CLONECELL" down "$SLOT_B" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A proof guest: a netns whose veth joins the CELL bridge exactly where the
# clone's tap would, carrying the shared MAC, the shared address and the warm
# (wrong) ARP entry a golden restores with.
make_guest() {
  local ns="$1" host_if="$2" cell_bridge="$3"
  ip netns add "$ns" || die "netns add $ns"
  install -d -m 0755 "/etc/netns/$ns"
  printf 'nameserver %s\n' "$GW" >"/etc/netns/$ns/resolv.conf"
  ip link add "$host_if" type veth peer name g0 netns "$ns" || die "veth $host_if"
  ip link set "$host_if" master "$cell_bridge" up || die "enslave $host_if to $cell_bridge"
  nsx "$ns" ip link set lo up
  nsx "$ns" ip link set g0 address "$GMAC"
  nsx "$ns" ip addr add "$GIP/24" dev g0
  nsx "$ns" ip link set g0 up
  # The stale cache: the gateway at a MAC that exists on no walk-in segment.
  nsx "$ns" ip neigh replace "$GW" lladdr "$STALE_MAC" dev g0 nud stale
}

[ "$(id -u)" = 0 ] || die "must run as root on labhost"
ip link show "$WI_BRIDGE" >/dev/null 2>&1 || die "$WI_BRIDGE absent — provision-walkin-net.sh --apply first"
[ -x "$CLONECELL" ] || die "$CLONECELL not installed — provision-walkin-net.sh --apply bridge"
[ -n "$LAN_IP" ] || die "could not read labhost's LAN address"
cleanup

hdr "build two cells whose guests are IDENTICAL on the wire ($GIP, $GMAC)"
BR_A="$("$CLONECELL" up "$SLOT_A" "$GIP" | tail -1)" || die "cell A up"
BR_B="$("$CLONECELL" up "$SLOT_B" "$GIP" | tail -1)" || die "cell B up"
make_guest "$NS_A" wi-cellpf-a0 "$BR_A"
make_guest "$NS_B" wi-cellpf-b0 "$BR_B"
printf '   cell A slot %s bridge %s peer %s\n' "$SLOT_A" "$BR_A" "$PEER_A"
printf '   cell B slot %s bridge %s peer %s\n' "$SLOT_B" "$BR_B" "$PEER_B"

hdr "the prime MUST repair the stale gateway entry, down the real path"
if "$CLONECELL" prime "$SLOT_A" "$GIP" --wait 10 >/dev/null; then ok "cell A primed"; else bad "cell A prime failed"; fi
if "$CLONECELL" prime "$SLOT_B" "$GIP" --wait 10 >/dev/null; then ok "cell B primed"; else bad "cell B prime failed"; fi
for ns in "$NS_A" "$NS_B"; do
  if nsx "$ns" ip neigh show "$GW" | grep -q "$STALE_MAC"; then
    bad "$ns still holds the stale MAC for $GW"
  else
    ok "$ns learned the cell's gateway MAC: $(nsx "$ns" ip neigh show "$GW" | awk '{print $5}')"
  fi
done

hdr "BOTH guests MUST reach the corpus web CONCURRENTLY"
must "A pings the gateway" "$NS_A" ping -c2 -W2 "$GW"
must "B pings the gateway" "$NS_B" ping -c2 -W2 "$GW"
must "A DNS" "$NS_A" sh -c "dig +short +time=3 +tries=1 @$GW spacejam.com | grep -E '^[0-9.]+\$'"
must "B DNS" "$NS_B" sh -c "dig +short +time=3 +tries=1 @$GW spacejam.com | grep -E '^[0-9.]+\$'"
tmpa="$(mktemp)"
tmpb="$(mktemp)"
nsx "$NS_A" sh -c "for i in 1 2 3 4 5; do curl -s -o /dev/null -w '%{http_code} ' --max-time 10 http://example.museum/; done" >"$tmpa" &
JA=$!
nsx "$NS_B" sh -c "for i in 1 2 3 4 5; do curl -s -o /dev/null -w '%{http_code} ' --max-time 10 http://example.museum/; done" >"$tmpb" &
JB=$!
wait $JA $JB
printf '         A: %s   B: %s\n' "$(cat "$tmpa")" "$(cat "$tmpb")"
grep -q "200 200 200 200 200" "$tmpa" && ok "A: 5/5 origin fetches while B fetched" || bad "A concurrent origin fetches"
grep -q "200 200 200 200 200" "$tmpb" && ok "B: 5/5 origin fetches while A fetched" || bad "B concurrent origin fetches"
rm -f "$tmpa" "$tmpb"
must "A proxy :3128" "$NS_A" curl -s -S -o /dev/null -w 'HTTP %{http_code}\n' --max-time 10 -x "$GW:3128" http://example.museum/
body="$(nsx "$NS_B" curl -s --max-time 15 'http://search.retronet/search?q=web' 2>&1)"
if grep -qi '<title>AltaVista:' <<<"$body" && grep -qi 'href="http://' <<<"$body"; then
  ok "B: search.retronet rendered a results page"
else
  bad "B: search.retronet returned no recognisable result page"
fi
grep -oiE '<title>[^<]*</title>' <<<"$body" | head -1 | sed 's/^/         | /'

hdr "the gateway MUST see two DISTINCT peers where the guests see themselves as one"
seen="$(pct exec 952 -- ip neigh show 2>/dev/null)"
grep -q "$PEER_A" <<<"$seen" && ok "CT 952 neighbours $PEER_A (cell A)" || bad "CT 952 never saw $PEER_A"
grep -q "$PEER_B" <<<"$seen" && ok "CT 952 neighbours $PEER_B (cell B)" || bad "CT 952 never saw $PEER_B"

hdr "a guest MUST NOT reach the other cell — the NEW case: an identical twin"
# The twin holds the guest's own address, so the only names by which it could
# be attacked are the cells' NAT peers on vmbr-wi.
mustnot "A -> B's NAT peer $PEER_B" "$NS_A" ping -c2 -W2 "$PEER_B"
mustnot "A -> B's NAT peer, TCP" "$NS_A" nc -z -w 3 "$PEER_B" 80
mustnot "B -> A's NAT peer $PEER_A" "$NS_B" ping -c2 -W2 "$PEER_A"
mustnot "cell A's namespace -> cell B's peer (isolated ports)" "wicell$SLOT_A" ping -c2 -W2 "$PEER_B"
must "B still reaches the gateway (isolation is not an outage)" "$NS_B" ping -c2 -W2 "$GW"

hdr "a guest MUST NOT reach the fleet, labhost or the internet"
mustnot "labhost's retronet address $RN_HOST_IP" "$NS_A" ping -c2 -W2 "$RN_HOST_IP"
mustnot "a live station, $RN_STATION" "$NS_A" ping -c2 -W2 "$RN_STATION"
mustnot "labhost's LAN address" "$NS_A" ping -c2 -W2 "$LAN_IP"
mustnot "the gallery on labhost:8443" "$NS_A" nc -z -w 3 "$LAN_IP" 8443
mustnot "the internet, $WAN_IP" "$NS_A" ping -c2 -W2 "$WAN_IP"
mustnot "OSCAR 5190 on the walk-in gateway" "$NS_A" nc -z -w 3 "$GW" 5190
mustnot "sshd 22 on the walk-in gateway" "$NS_A" nc -z -w 3 "$GW" 22

hdr "the LIVE retronet is unharmed"
if [ "$(pct config 951 | grep -c '^net')" = 1 ]; then ok "CT 951 is still single-homed"; else bad "CT 951 grew an interface"; fi
if nc -z -w 3 "$GW" 5190; then ok "retronet OSCAR 5190 answers from labhost (that is CT 951 out here)"; else bad "retronet OSCAR 5190 DOWN"; fi

hdr "result"
printf '   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
echo "   multi-clone plane contained: two identical machines, one corpus web each, nothing else."
