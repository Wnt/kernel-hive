#!/usr/bin/env bash
# prove-containment.sh — stand up two throwaway "clones" on vmbr-wi and DEMONSTRATE,
# from the outside, that the walk-in plane does what it claims.
#
#   ssh lab '/data/kernel-hive/scripts/retronet/walkin-net/prove-containment.sh'
#
# Containment is proven, never assumed. A rule that is present is not a rule
# that works: the interesting failures on this box have all been rules that read
# back correctly and did nothing (a lost xtables race, br_netfilter changing
# which hook sees a frame, a bridge driver too old for a port flag). So this
# script does not inspect the ruleset. It creates two network namespaces, gives
# each a veth whose host end is a walk-in tap on vmbr-wi, leases an address the
# way a clone does, and then TRIES the things a clone must not be able to do.
#
# The two namespaces are as close to a clone as a shell can get: no default
# route beyond what DHCP hands them (which is none), an isolated bridge port,
# and nothing else. They are torn down at the end, always — teardown is part of
# "done".
#
# Every check prints the command's own output. A check that must fail is
# reported as PASS when it fails, and the script exits non-zero if ANY check
# comes out the wrong way.
set -uo pipefail

WI_BRIDGE="${WI_BRIDGE:-vmbr-wi}"
WI_GATEWAY_IP="${WI_GATEWAY_IP:-10.98.0.2}"
WI_HOST_IP="${WI_HOST_IP:-10.98.0.1}"
# The retronet, i.e. "the fleet": the gateway's OTHER leg (same box — the single
# most dangerous target on the plane) and labhost's retronet address.
RN_GATEWAY_IP="${RN_GATEWAY_IP:-10.99.0.2}"
RN_HOST_IP="${RN_HOST_IP:-10.99.0.1}"
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
  cleanup
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
    if ip netns list 2>/dev/null | grep -qw "$ns"; then
      # Release the lease politely, then take the namespace down. Deleting the
      # netns kills what runs in it — no pkill anywhere near this box.
      nsx "$ns" dhclient -r -lf "/run/$ns.leases" -pf "/run/$ns.pid" "$IN_IF" >/dev/null 2>&1 || true
      ip netns del "$ns" 2>/dev/null || true
    fi
    rm -rf "/etc/netns/$ns" "/run/$ns.leases" "/run/$ns.pid" 2>/dev/null || true
  done
  for tap in "$TAP_A" "$TAP_B"; do
    ip link del "$tap" 2>/dev/null || true
  done
}

make_clone() {
  local ns="$1" tap="$2"
  ip netns del "$ns" 2>/dev/null || true
  ip link del "$tap" 2>/dev/null || true
  ip netns add "$ns" || die "netns add $ns"
  # `ip netns exec` bind-mounts /etc/netns/<ns>/* over /etc/*, so dhclient's
  # resolv.conf lands in the namespace and NEVER touches labhost's.
  install -d -m 0755 "/etc/netns/$ns"
  : >"/etc/netns/$ns/resolv.conf"
  ip link add "$tap" type veth peer name "$IN_IF" || die "veth $tap"
  ip link set "$IN_IF" netns "$ns"
  ip link set "$tap" master "$WI_BRIDGE" || die "enslave $tap to $WI_BRIDGE"
  ip link set "$tap" up
  nsx "$ns" ip link set lo up
  nsx "$ns" ip link set "$IN_IF" up
  # The helper lanes 7/8/10 call, used here exactly as they will use it.
  /usr/local/sbin/wi-isolate on "$tap" >/dev/null || die "wi-isolate on $tap"
}

lease() {
  local ns="$1"
  nsx "$ns" dhclient -1 -lf "/run/$ns.leases" -pf "/run/$ns.pid" "$IN_IF" >/dev/null 2>&1 || true
  nsx "$ns" ip -4 -o addr show "$IN_IF" | awk '{print $4}' | cut -d/ -f1 | head -1
}

trap cleanup EXIT

[ "$(id -u)" = 0 ] || die "must run as root on labhost"
ip link show "$WI_BRIDGE" >/dev/null 2>&1 || die "$WI_BRIDGE absent — run provision-walkin-net.sh --apply first"
[ -n "$LAN_IP" ] || die "could not read labhost's LAN address from ${WI_LAN_IF:-vmbr0}"

hdr "stand up two clones on $WI_BRIDGE (isolated ports, DHCP leases)"
make_clone "$NS_A" "$TAP_A"
make_clone "$NS_B" "$TAP_B"
IP_A="$(lease "$NS_A")"
IP_B="$(lease "$NS_B")"
printf '   clone A %-12s %s (tap %s)\n' "$NS_A" "${IP_A:-NO LEASE}" "$TAP_A"
printf '   clone B %-12s %s (tap %s)\n' "$NS_B" "${IP_B:-NO LEASE}" "$TAP_B"
/usr/local/sbin/wi-isolate show

if [ -n "$IP_A" ] && [ -n "$IP_B" ]; then
  ok "DHCP: both clones leased from the walk-in pool ($IP_A, $IP_B)"
else
  bad "DHCP: a clone did not get a lease (A='${IP_A:-}' B='${IP_B:-}')"
fi
case "$IP_A" in 10.98.0.1[0-9][0-9]) ok "clone A is inside the frozen pool 10.98.0.100-199" ;; *) bad "clone A leased $IP_A — outside the walk-in pool" ;; esac
# No default route is the addressing-level lock: the DHCP scope never sends
# option 3, so there is nothing to route through even if a rule were missing.
if [ -z "$(nsx "$NS_A" ip route show default)" ]; then
  ok "clone A has NO default route (option 3 withheld)"
else
  bad "clone A HAS a default route: $(nsx "$NS_A" ip route show default)"
fi

hdr "it MUST reach the corpus web on $WI_GATEWAY_IP"
must "ping the walk-in gateway" "$NS_A" ping -c2 -W2 "$WI_GATEWAY_IP"
must "DNS: any name resolves to the gateway" "$NS_A" dig +short +time=3 +tries=1 "@$WI_GATEWAY_IP" spacejam.com
must "origin :80 (seamless, no proxy)" "$NS_A" curl -s -S -o /dev/null -w 'HTTP %{http_code}\n' --max-time 8 "http://$WI_GATEWAY_IP/"
must "proxy :3128" "$NS_A" curl -s -S -o /dev/null -w 'HTTP %{http_code}\n' --max-time 8 -x "$WI_GATEWAY_IP:3128" http://example.museum/
must "search.retronet through the proxy" "$NS_A" curl -s -S -o /dev/null -w 'HTTP %{http_code}\n' --max-time 8 -x "$WI_GATEWAY_IP:3128" http://search.retronet/

hdr "it MUST NOT reach the fleet (10.99.0.0/24)"
mustnot "the gateway's OTHER leg $RN_GATEWAY_IP (same box — transit)" "$NS_A" ping -c1 -W2 "$RN_GATEWAY_IP"
mustnot "the retronet corpus origin $RN_GATEWAY_IP:80" "$NS_A" curl -s -S -o /dev/null --max-time 5 "http://$RN_GATEWAY_IP/"
mustnot "labhost's retronet address $RN_HOST_IP" "$NS_A" ping -c1 -W2 "$RN_HOST_IP"
mustnot "a retronet station (10.99.0.27, win311)" "$NS_A" ping -c1 -W2 10.99.0.27

hdr "it MUST NOT reach OSCAR — the fleet's chat relay is not a walk-in service"
mustnot "OSCAR 5190 on the walk-in leg" "$NS_A" nc -z -w 3 "$WI_GATEWAY_IP" 5190
mustnot "OSCAR slirp door 5191 on the walk-in leg" "$NS_A" nc -z -w 3 "$WI_GATEWAY_IP" 5191
mustnot "TOC 9898 on the walk-in leg" "$NS_A" nc -z -w 3 "$WI_GATEWAY_IP" 9898
mustnot "sshd 22 on the walk-in leg" "$NS_A" nc -z -w 3 "$WI_GATEWAY_IP" 22
mustnot "OSCAR 5190 on the retronet leg" "$NS_A" nc -z -w 3 "$RN_GATEWAY_IP" 5190

hdr "it MUST NOT reach labhost"
mustnot "labhost's bridge address $WI_HOST_IP" "$NS_A" ping -c1 -W2 "$WI_HOST_IP"
mustnot "the gallery on $WI_HOST_IP:8443" "$NS_A" nc -z -w 3 "$WI_HOST_IP" 8443
mustnot "sshd on $WI_HOST_IP:22" "$NS_A" nc -z -w 3 "$WI_HOST_IP" 22
mustnot "labhost's LAN address (read at runtime, never committed)" "$NS_A" ping -c1 -W2 "$LAN_IP"

hdr "it MUST NOT reach the internet"
mustnot "ping $WAN_IP" "$NS_A" ping -c1 -W2 "$WAN_IP"
mustnot "http to $WAN_IP" "$NS_A" curl -s -S -o /dev/null --max-time 5 "http://$WAN_IP/"
mustnot "real DNS resolution off-box" "$NS_A" dig +short +time=3 +tries=1 "@$WAN_IP" example.com

hdr "it MUST NOT reach another clone (kernel-enforced port isolation)"
mustnot "clone A -> clone B ($IP_B)" "$NS_A" ping -c1 -W2 "$IP_B"
mustnot "clone B -> clone A ($IP_A)" "$NS_B" ping -c1 -W2 "$IP_A"
mustnot "clone A -> clone B, TCP" "$NS_A" nc -z -w 3 "$IP_B" 80
must "clone B still reaches the gateway (isolation is not an outage)" "$NS_B" ping -c2 -W2 "$WI_GATEWAY_IP"

hdr "the LIVE retronet is unharmed"
if curl -s -o /dev/null --max-time 5 "http://$RN_GATEWAY_IP/"; then ok "retronet corpus origin answers from labhost"; else bad "retronet corpus origin DOWN"; fi
if nc -z -w 3 "$RN_GATEWAY_IP" 5190; then ok "retronet OSCAR 5190 answers from labhost"; else bad "retronet OSCAR 5190 DOWN"; fi
if dig +short +time=3 +tries=1 "@$RN_GATEWAY_IP" anything.test | grep -q "$RN_GATEWAY_IP"; then
  ok "retronet wildcard DNS answers from labhost"
else bad "retronet wildcard DNS DOWN"; fi

hdr "result"
printf '   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
echo "   walk-in plane contained: corpus web only."
