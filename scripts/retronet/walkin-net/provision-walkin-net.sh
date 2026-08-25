#!/usr/bin/env bash
# provision-walkin-net.sh — build the walk-in network plane, one command,
# idempotent, and re-running it is the repair path.
#
#   ssh lab '/data/kernel-hive/scripts/retronet/walkin-net/provision-walkin-net.sh --apply'
#
# THE PLANE IN ONE LINE: a walk-in clone reaches the corpus web on the gateway
# CT and NOTHING else — not the fleet, not labhost, not the internet, not
# another clone. Frozen values: docs/lab/walkin/CONTRACT-LEDGER.md §6.
# As-built and the containment proofs: docs/lab/walkin/NETWORK-PLANE.md.
#
# Steps, each runnable on its own:
#   bridge    vmbr-wi (bridge-ports none, 10.98.0.1/24) + walkin-fw + wi-isolate
#   ct        CT 951 gains net1 on vmbr-wi at 10.98.0.2/24, plus the in-CT
#             no-transit ruleset (nft table inet walkin + ip_forward=0)
#   retronet  re-pin the EXISTING retronet DHCP scope to eth0 — see WHY below
#   services  walkin-dhcp / walkin-dns / walkin-proxy, on eth1 only
#   verify    the services answer, and the live retronet is unharmed
#
# WHY THE `retronet` STEP TOUCHES A LIVE SERVICE. Giving CT 951 a second leg
# turns its one DHCP server into a server that hears both legs: a DISCOVER is a
# limited broadcast and the kernel delivers a broadcast to EVERY matching
# socket. Left alone, the retronet scope would answer walk-in clones with
# 10.99.0.0/24 addresses. Both scopes are therefore pinned to their own leg with
# SO_BINDTODEVICE. The retronet's own installer does that re-pin
# (scripts/retronet/web/install-dhcp.sh), so this step calls it rather than
# reaching into the CT — and its `verify` is the check that the live plane
# still leases.
#
# The containment proof is a separate script on purpose: prove-containment.sh.
# It stands up two throwaway netns "clones" and demonstrates the four locks from
# the outside. Containment is proven, never assumed.
set -euo pipefail

WI_VMID="${WI_VMID:-951}"
WI_BRIDGE="${WI_BRIDGE:-vmbr-wi}"
WI_HOST_IP="${WI_HOST_IP:-10.98.0.1}"
WI_GATEWAY_IP="${WI_GATEWAY_IP:-10.98.0.2}"
WI_CIDR="${WI_CIDR:-24}"
WI_CT_IF="${WI_CT_IF:-eth1}"
WI_POOL="${WI_POOL:-10.98.0.100-10.98.0.199}"
WI_LEASE="${WI_LEASE:-300}"
WI_DNS_TTL="${WI_DNS_TTL:-60}"
WI_DOMAIN="${WI_DOMAIN:-retronet.lab}"
WI_CORPUS="${WI_CORPUS:-/data/retronet/corpus}"
WI_SEARCH_HOSTS="${WI_SEARCH_HOSTS:-search.retronet}"
WI_SEARCH_BACKEND="${WI_SEARCH_BACKEND:-127.0.0.1:8090}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY=0

say() { printf '\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die() {
  printf 'provision-walkin-net: %s\n' "$*" >&2
  exit 1
}

need_labhost() {
  command -v pct >/dev/null 2>&1 || die "no pct — this runs ON labhost (ssh lab '...')"
  [ "$(id -u)" = 0 ] || die "must run as root on labhost"
}

ctexec() { pct exec "$WI_VMID" -- "$@"; }
ctsh() {
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  pct push "$WI_VMID" "$tmp" /tmp/.wi-step.sh --perms 700
  rm -f "$tmp"
  pct exec "$WI_VMID" -- /bin/bash /tmp/.wi-step.sh
}

render() {
  local out="$1" v
  shift
  out="$(cat "$out")"
  for v in "$@"; do out="${out//@$v@/${!v}}"; done
  printf '%s\n' "$out"
}

# --- bridge ------------------------------------------------------------------

step_bridge() {
  say "bridge $WI_BRIDGE ($WI_HOST_IP/$WI_CIDR, bridge-ports none) + containment"
  local iface="/etc/network/interfaces.d/$WI_BRIDGE"
  if [ "$APPLY" = 0 ]; then
    info "PLAN: write $iface; install /usr/local/sbin/walkin-fw and /usr/local/sbin/wi-isolate; ifup $WI_BRIDGE"
    return
  fi
  install -m 0755 "$HERE/walkin-fw.sh" /usr/local/sbin/walkin-fw
  install -m 0755 "$HERE/wi-isolate.sh" /usr/local/sbin/wi-isolate
  cat >"$iface" <<EOF
# walk-in bridge — written by scripts/retronet/walkin-net/provision-walkin-net.sh.
# Sibling of vmbr-rn and built to the same pattern: NO uplink, NO gateway. This
# /24 exists only between labhost, the retronet gateway CT's second leg, and the
# ephemeral walk-in clones. docs/lab/walkin/NETWORK-PLANE.md.
auto $WI_BRIDGE
iface $WI_BRIDGE inet static
	address $WI_HOST_IP/$WI_CIDR
	bridge-ports none
	bridge-stp off
	bridge-fd 0
	post-up /usr/local/sbin/walkin-fw up $WI_BRIDGE
	post-down /usr/local/sbin/walkin-fw down $WI_BRIDGE
EOF
  if ! ip link show "$WI_BRIDGE" >/dev/null 2>&1; then
    ifup "$WI_BRIDGE" || die "ifup $WI_BRIDGE failed"
    info "created $WI_BRIDGE"
  else
    info "$WI_BRIDGE already up"
  fi
  # Re-assert the rules whether or not ifup ran (post-up only fires on a create).
  /usr/local/sbin/walkin-fw up "$WI_BRIDGE" || die "walkin-fw up failed"
  info "walkin-fw asserted: FORWARD closed both ways, INPUT replies-only"
}

# --- ct ----------------------------------------------------------------------

step_ct() {
  say "CT $WI_VMID: net1 on $WI_BRIDGE at $WI_GATEWAY_IP/$WI_CIDR + no-transit"
  if [ "$APPLY" = 0 ]; then
    info "PLAN: pct set $WI_VMID -net1 name=$WI_CT_IF,bridge=$WI_BRIDGE,firewall=0,ip=$WI_GATEWAY_IP/$WI_CIDR,ip6=manual,type=veth"
    info "PLAN: /etc/nftables.d/walkin-net.nft + /etc/sysctl.d/90-walkin-no-transit.conf + walkin-net.service"
    return
  fi
  # net0 is NOT named here, so the live retronet leg is not rewritten. pct set
  # hot-plugs the new veth into the running CT; eth0 keeps its address, its MAC
  # and its carrier throughout.
  if pct config "$WI_VMID" | grep -q "^net1:.*bridge=$WI_BRIDGE"; then
    info "net1 already present"
  else
    pct set "$WI_VMID" -net1 "name=$WI_CT_IF,bridge=$WI_BRIDGE,firewall=0,ip=$WI_GATEWAY_IP/$WI_CIDR,ip6=manual,type=veth" ||
      die "pct set -net1 failed"
    info "net1 added"
  fi
  ctexec ip -4 -o addr show "$WI_CT_IF" 2>/dev/null | grep -q "$WI_GATEWAY_IP" ||
    die "CT $WI_CT_IF did not come up with $WI_GATEWAY_IP"

  pct push "$WI_VMID" "$HERE/walkin-net.nft" /tmp/wi-walkin-net.nft --perms 644
  pct push "$WI_VMID" "$HERE/walkin-net.service" /tmp/wi-walkin-net.service --perms 644
  ctsh <<'EOF'
set -euo pipefail
install -d -m 0755 /etc/nftables.d
install -o root -g root -m 0644 /tmp/wi-walkin-net.nft /etc/nftables.d/walkin-net.nft
install -o root -g root -m 0644 /tmp/wi-walkin-net.service /etc/systemd/system/walkin-net.service
cat >/etc/sysctl.d/90-walkin-no-transit.conf <<'SYSCTL'
# CT 951 is dual-homed (eth0 retronet, eth1 walk-in) and a dual-homed box IS a
# router unless something stops it. Nothing in this container ever routes.
# Second lock: the nft `forward` chain in /etc/nftables.d/walkin-net.nft.
# docs/lab/walkin/NETWORK-PLANE.md
net.ipv4.ip_forward = 0
SYSCTL
rm -f /tmp/wi-walkin-net.nft /tmp/wi-walkin-net.service /tmp/.wi-step.sh
systemctl daemon-reload
systemctl enable --now walkin-net.service
systemctl restart walkin-net.service
EOF
  ctexec sh -c 'nft list table inet walkin >/dev/null' || die "nft table inet walkin did not load in CT $WI_VMID"
  [ "$(ctexec cat /proc/sys/net/ipv4/ip_forward)" = "0" ] || die "ip_forward is still 1 in CT $WI_VMID"
  info "no-transit asserted: ip_forward=0 + nft table inet walkin"
}

# --- retronet re-pin ---------------------------------------------------------

step_retronet() {
  say "re-pin the retronet DHCP scope to eth0 (it must stop hearing $WI_CT_IF)"
  local inst="$HERE/../web/install-dhcp.sh"
  [ -x "$inst" ] || die "missing $inst"
  if [ "$APPLY" = 0 ]; then
    info "PLAN: $inst --apply install verify   (renders RN_DHCP_BIND_DEVICE=eth0)"
    return
  fi
  "$inst" --apply install verify || die "retronet DHCP re-pin failed — the LIVE plane is the one at risk here"
  info "retronet scope pinned to eth0 and verified"
}

# --- services ----------------------------------------------------------------

step_services() {
  say "walk-in services on $WI_CT_IF: DHCP $WI_POOL (${WI_LEASE}s), DNS, proxy+origin"
  local RN_DHCP_LISTEN="0.0.0.0:67" RN_DHCP_BIND_DEVICE="$WI_CT_IF"
  local RN_DHCP_SERVER_ID="$WI_GATEWAY_IP" RN_DHCP_SUBNET_MASK="255.255.255.0"
  local RN_DHCP_DNS="$WI_GATEWAY_IP" RN_DHCP_DOMAIN="$WI_DOMAIN"
  local RN_DHCP_POOL="$WI_POOL" RN_DHCP_LEASE="$WI_LEASE"
  local RN_DNS_LISTEN="$WI_GATEWAY_IP:53" RN_DNS_ANSWER="$WI_GATEWAY_IP" RN_DNS_TTL="$WI_DNS_TTL"
  local RN_PROXY_LISTEN="$WI_GATEWAY_IP:3128" RN_PROXY_ORIGIN_LISTEN="$WI_GATEWAY_IP:80"
  local RN_PROXY_CORPUS="$WI_CORPUS" RN_PROXY_SEARCH_HOSTS="$WI_SEARCH_HOSTS"
  local RN_PROXY_SEARCH_BACKEND="$WI_SEARCH_BACKEND"

  if [ "$APPLY" = 0 ]; then
    info "PLAN: render /etc/retronet/walkin-{dhcp,dns,proxy}.env in CT $WI_VMID"
    info "PLAN: install + enable + start walkin-dhcp/-dns/-proxy.service"
    return
  fi

  # The programs are the retronet's, already installed and already read-only:
  # these are second UNITS, not a second copy of the code.
  for d in /opt/retronet-dhcp/dhcp.py /opt/retronet-dns/dns.py /opt/retronet-proxy/proxy.py; do
    ctexec test -f "$d" || die "$d absent in CT $WI_VMID — install the retronet web plane first (WEB-PROXY.md)"
  done

  local tmp
  tmp="$(mktemp -d)"
  render "$HERE/walkin-dhcp.env.tmpl" RN_DHCP_LISTEN RN_DHCP_BIND_DEVICE RN_DHCP_SERVER_ID \
    RN_DHCP_SUBNET_MASK RN_DHCP_DNS RN_DHCP_DOMAIN RN_DHCP_POOL RN_DHCP_LEASE >"$tmp/walkin-dhcp.env"
  render "$HERE/walkin-dns.env.tmpl" RN_DNS_LISTEN RN_DNS_ANSWER RN_DNS_TTL >"$tmp/walkin-dns.env"
  render "$HERE/walkin-proxy.env.tmpl" RN_PROXY_LISTEN RN_PROXY_ORIGIN_LISTEN RN_PROXY_CORPUS \
    RN_PROXY_SEARCH_HOSTS RN_PROXY_SEARCH_BACKEND >"$tmp/walkin-proxy.env"
  local f
  for f in walkin-dhcp.env walkin-dns.env walkin-proxy.env; do
    pct push "$WI_VMID" "$tmp/$f" "/tmp/wi-$f" --perms 644
  done
  for f in walkin-dhcp.service walkin-dns.service walkin-proxy.service; do
    pct push "$WI_VMID" "$HERE/$f" "/tmp/wi-$f" --perms 644
  done
  rm -rf "$tmp"

  ctsh <<'EOF'
set -euo pipefail
install -d -o root -g root -m 0755 /etc/retronet
install -o root -g rndhcp -m 0640 /tmp/wi-walkin-dhcp.env /etc/retronet/walkin-dhcp.env
install -o root -g rndns  -m 0640 /tmp/wi-walkin-dns.env  /etc/retronet/walkin-dns.env
install -o root -g rnproxy -m 0640 /tmp/wi-walkin-proxy.env /etc/retronet/walkin-proxy.env
for u in walkin-dhcp walkin-dns walkin-proxy; do
  install -o root -g root -m 0644 "/tmp/wi-$u.service" "/etc/systemd/system/$u.service"
done
rm -f /tmp/wi-walkin-*.env /tmp/wi-walkin-*.service /tmp/.wi-step.sh
systemctl daemon-reload
for u in walkin-dhcp walkin-dns walkin-proxy; do
  systemctl enable --now "$u.service"
  systemctl restart "$u.service"
done
EOF
  local u
  for u in walkin-dhcp walkin-dns walkin-proxy; do
    ctexec systemctl is-active --quiet "$u.service" ||
      die "$u did not start — pct exec $WI_VMID -- journalctl -u $u"
    info "$u active"
  done
}

# --- verify ------------------------------------------------------------------

step_verify() {
  say "verify"
  local fail=0
  probe() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then info "PASS  $label"; else
      info "FAIL  $label"
      fail=1
    fi
  }

  probe "$WI_BRIDGE is up" ip link show "$WI_BRIDGE"
  probe "$WI_BRIDGE has no uplink (bridge-ports none)" \
    grep -qx $'\tbridge-ports none' "/etc/network/interfaces.d/$WI_BRIDGE"
  probe "walkin-fw rules in the kernel" /usr/local/sbin/walkin-fw verify "$WI_BRIDGE"
  probe "CT $WI_CT_IF is $WI_GATEWAY_IP" sh -c "pct exec $WI_VMID -- ip -4 -o addr show $WI_CT_IF | grep -q $WI_GATEWAY_IP"
  probe "CT ip_forward=0" sh -c "[ \"\$(pct exec $WI_VMID -- cat /proc/sys/net/ipv4/ip_forward)\" = 0 ]"
  probe "CT nft table inet walkin loaded" sh -c "pct exec $WI_VMID -- nft list table inet walkin >/dev/null"
  probe "walkin-net.service enabled (survives a CT reboot)" sh -c "pct exec $WI_VMID -- systemctl is-enabled --quiet walkin-net.service"
  local u
  for u in walkin-dhcp walkin-dns walkin-proxy; do
    probe "$u active" sh -c "pct exec $WI_VMID -- systemctl is-active --quiet $u.service"
    probe "$u enabled" sh -c "pct exec $WI_VMID -- systemctl is-enabled --quiet $u.service"
  done
  probe "walk-in DNS answers on $WI_GATEWAY_IP" sh -c "dig +short +time=3 +tries=1 @$WI_GATEWAY_IP anything.test | grep -q $WI_GATEWAY_IP"
  probe "walk-in origin answers on $WI_GATEWAY_IP:80" sh -c "curl -s -o /dev/null --max-time 5 http://$WI_GATEWAY_IP/"

  # The live plane must be exactly as it was.
  probe "LIVE retronet: OSCAR still answers on 10.99.0.2:5190" nc -z -w 3 10.99.0.2 5190
  probe "LIVE retronet: corpus origin still answers on 10.99.0.2:80" sh -c "curl -s -o /dev/null --max-time 5 http://10.99.0.2/"
  probe "LIVE retronet: DNS still answers on 10.99.0.2" sh -c "dig +short +time=3 +tries=1 @10.99.0.2 anything.test | grep -q 10.99.0.2"
  probe "LIVE retronet: DHCP scope pinned to eth0" sh -c "pct exec $WI_VMID -- grep -q '^RN_DHCP_BIND_DEVICE=eth0' /etc/retronet/dhcp.env"

  [ "$fail" = 0 ] || die "verification failed"
  say "walk-in network plane OK — now run prove-containment.sh for the four locks"
}

# --- main --------------------------------------------------------------------

STEPS=()
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h | --help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    bridge | ct | retronet | services | verify) STEPS+=("$a") ;;
    *) die "unknown arg: $a (want --apply | bridge | ct | retronet | services | verify)" ;;
  esac
done
[ "${#STEPS[@]}" -gt 0 ] || STEPS=(bridge ct retronet services verify)

need_labhost
for s in "${STEPS[@]}"; do "step_$s"; done
