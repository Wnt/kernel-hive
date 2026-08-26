#!/usr/bin/env bash
# provision-walkin-net.sh — build the walk-in network plane from nothing, one
# command, idempotent, and re-running it is the repair path.
#
#   ssh lab '/data/kernel-hive/scripts/retronet/walkin-net/provision-walkin-net.sh --apply'
#
# THE PLANE IN ONE LINE: a walk-in clone reaches the corpus web and NOTHING
# else — not the fleet, not labhost, not the internet, not another clone.
# Frozen values: docs/lab/walkin/CONTRACT-LEDGER.md §6. As-built and the
# containment proofs: docs/lab/walkin/NETWORK-PLANE.md.
#
# Steps, each runnable on its own:
#   bridge    vmbr-wi — bridge-ports none, NO ADDRESS ON LABHOST — plus
#             walkin-fw plus the helpers other lanes call: wi-isolate
#             (per-tap), wi-warm-arp (per-clone, flat-plane) and wi-clonecell
#             (per-clone L2 cell + NAT, the broker's multi-clone path).
#   ct        CT 952 `walkin-gw`: unprivileged Debian, SINGLE-HOMED on vmbr-wi
#             at 10.99.0.2/24, no default route, corpus mounted READ-ONLY.
#   services  the retronet web plane's own installers, pointed at CT 952: the
#             wildcard resolver, the :3128 proxy + :80 origin, and search.
#             No OSCAR — the chat relay is a station-to-station service.
#   verify    what can honestly be checked from labhost (see the warning below).
#
# THE NUMBERING TRAP, and it is the thing to know before touching this plane.
# vmbr-wi presents 10.99.0.0/24 with the gateway at 10.99.0.2 — the SAME
# numbering as the retronet, on a different L2 with no route between them. That
# is deliberate: every golden carries the network identity it was captured with
# on vmbr-rn, and these guests do not re-DHCP inside a session, so presenting
# the numbering they already expect is what lets a clone boot believing exactly
# what it believed when captured (contract ledger §5.3).
#
# The cost is that FROM LABHOST, `10.99.0.2` IS THE RETRONET GATEWAY. labhost
# has a route to that /24 via vmbr-rn and none via vmbr-wi (it holds no address
# there at all). So a curl or a dig aimed at 10.99.0.2 from labhost tests CT
# 951 and always will — which is why the retronet installers' own `verify`
# steps are NOT run for CT 952 below: they would pass by testing the wrong
# machine. The walk-in services can only be verified from a port of vmbr-wi,
# which is what prove-containment.sh does.
#
# CT 951 IS NOT TOUCHED BY THIS SCRIPT. The live retronet gateway serves five
# ICQ stations and the corpus web; the walk-in plane gets its own container
# precisely so that it never has to.
set -euo pipefail

WI_VMID="${WI_VMID:-952}"
WI_HOSTNAME="${WI_HOSTNAME:-walkin-gw}"
WI_BRIDGE="${WI_BRIDGE:-vmbr-wi}"
WI_CT_IP="${WI_CT_IP:-10.99.0.2}"
WI_PREFIX="${WI_PREFIX:-24}"
WI_TEMPLATE="${WI_TEMPLATE:-local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst}"
WI_STORAGE="${WI_STORAGE:-data}"
WI_DISK_GB="${WI_DISK_GB:-8}"
WI_CORES="${WI_CORES:-2}"
# 2048, matching CT 951. The search service builds its inverted index in memory
# over the whole corpus (~500 MB peak), and install-search.sh runs a second
# `search.py index` alongside the running service as its verify step. At 1024 the
# two together are OOM-killed, and the symptom is not an error but a service that
# reports `active` while refusing every connection — which the proxy renders to a
# visitor as "Search Is Offline".
WI_MEM_MB="${WI_MEM_MB:-2048}"
WI_CORPUS_SRC="${WI_CORPUS_SRC:-/data/vms/retronet-corpus}"
WI_CORPUS="${WI_CORPUS:-/data/retronet/corpus}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IFACE_FILE="/etc/network/interfaces.d/$WI_BRIDGE"
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

# --- 1. bridge ---------------------------------------------------------------

step_bridge() {
  say "bridge $WI_BRIDGE (no uplink, NO address on labhost)"
  if [ "$APPLY" = 0 ]; then
    info "PLAN: write $IFACE_FILE; install /usr/local/sbin/{walkin-fw,wi-isolate,wi-warm-arp,wi-clonecell}; ifup $WI_BRIDGE"
    return
  fi
  install -m 0755 "$HERE/walkin-fw.sh" /usr/local/sbin/walkin-fw
  install -m 0755 "$HERE/wi-isolate.sh" /usr/local/sbin/wi-isolate
  install -m 0755 "$HERE/wi-warm-arp.sh" /usr/local/sbin/wi-warm-arp
  install -m 0755 "$HERE/wi-clonecell.sh" /usr/local/sbin/wi-clonecell

  # `inet manual`, not `inet static`: labhost is not a participant on this
  # segment. It holds no address, so there is nothing for a clone to dial and
  # nothing to route through — and, on a plane that reuses the retronet's
  # numbering, no second route to 10.99.0.0/24 either.
  cat >"$IFACE_FILE" <<EOF
# walk-in bridge — written by scripts/retronet/walkin-net/provision-walkin-net.sh.
# NO uplink (bridge-ports none) and NO ADDRESS: this segment carries only the
# walk-in gateway CT $WI_VMID and the ephemeral clone taps, each of which is
# isolated from the others. labhost is not on it.
# docs/lab/walkin/NETWORK-PLANE.md
auto $WI_BRIDGE
iface $WI_BRIDGE inet manual
	bridge-ports none
	bridge-stp off
	bridge-fd 0
	post-up /usr/local/sbin/walkin-fw up $WI_BRIDGE
	post-down /usr/local/sbin/walkin-fw down $WI_BRIDGE
EOF
  # `ifup <iface>`, never `ifreload -a`: reloading every interface on a box
  # whose only route to the world is vmbr0 is not a risk worth taking for an
  # interface with no dependencies.
  if ip link show "$WI_BRIDGE" >/dev/null 2>&1; then
    info "already exists"
  else
    ifup "$WI_BRIDGE" || die "ifup $WI_BRIDGE failed"
    info "created"
  fi
  # An earlier revision of this plane gave labhost 10.98.0.1 here. If that
  # address is still on the interface, take it off — an addressed bridge is a
  # participant, and the whole point is that labhost is not one.
  local a
  for a in $(ip -4 -o addr show "$WI_BRIDGE" 2>/dev/null | awk '{print $4}'); do
    ip addr del "$a" dev "$WI_BRIDGE" && info "removed stale host address $a"
  done
  ip link set dev "$WI_BRIDGE" up
  /usr/local/sbin/walkin-fw up "$WI_BRIDGE" || die "walkin-fw up failed"
  info "walkin-fw asserted: FORWARD closed both ways, INPUT dropped, arp_ignore=8"
  ip -br addr show "$WI_BRIDGE" | sed 's/^/   /'
}

# --- 2. container ------------------------------------------------------------

step_ct() {
  say "CT $WI_VMID ($WI_HOSTNAME, $WI_CT_IP/$WI_PREFIX on $WI_BRIDGE, single-homed)"
  if [ "$APPLY" = 0 ]; then
    info "PLAN: pct create $WI_VMID from $WI_TEMPLATE, unprivileged, nesting=1"
    info "PLAN: net0 on $WI_BRIDGE at $WI_CT_IP/$WI_PREFIX, NO gw; corpus mounted READ-ONLY"
    return
  fi
  [ -d "$WI_CORPUS_SRC" ] || die "corpus $WI_CORPUS_SRC absent — the retronet web plane owns it"
  if pct status "$WI_VMID" >/dev/null 2>&1; then
    info "exists — reconciling config"
  else
    pct create "$WI_VMID" "$WI_TEMPLATE" \
      --hostname "$WI_HOSTNAME" \
      --unprivileged 1 \
      --cores "$WI_CORES" --memory "$WI_MEM_MB" --swap 512 \
      --rootfs "$WI_STORAGE:$WI_DISK_GB" \
      --ostype debian \
      --description "walk-in gateway: corpus web only, no OSCAR, no uplink. docs/lab/walkin/NETWORK-PLANE.md" ||
      die "pct create $WI_VMID failed"
  fi

  # No `gw=` and no `gw6=`. That omission IS the no-WAN guarantee: with no
  # default route the CT's own stack answers "Network is unreachable" before a
  # packet is ever built. ONE interface, so there is nothing to forward either.
  #
  # nesting=1 is not about running containers in here: Debian 13's systemd 257
  # needs it to mount /tmp, /run/lock and /dev/mqueue in an unprivileged CT, and
  # without it the machine boots degraded. It grants no host access.
  #
  # ro=1 on the corpus. The walk-in gateway SERVES the museum's corpus and must
  # never be able to change it — the crawl that fills it lives on the retronet
  # side, and an anonymous visitor's gateway has no business writing there.
  # `pct set` reconciles an EXISTING container too, so memory belongs here and
  # not only on the create path: the first build of this CT was created at 1024
  # and the fix had to be applied twice.
  pct set "$WI_VMID" \
    --memory "$WI_MEM_MB" --swap 512 \
    --net0 "name=eth0,bridge=$WI_BRIDGE,ip=$WI_CT_IP/$WI_PREFIX,ip6=manual,firewall=0" \
    --mp0 "$WI_CORPUS_SRC,mp=$WI_CORPUS,ro=1,backup=0" \
    --features nesting=1 \
    --onboot 1 \
    --nameserver "$WI_CT_IP" --searchdomain retronet.lab ||
    die "pct set $WI_VMID failed"

  [ "$(pct status "$WI_VMID")" = "status: running" ] || pct start "$WI_VMID"
  local _
  for _ in $(seq 30); do
    ctexec true >/dev/null 2>&1 && break
    sleep 1
  done
  ctexec true >/dev/null 2>&1 || die "CT $WI_VMID did not come up"
  info "up: $(ctexec hostname) $(ctexec hostname -I)"
  ctexec ip route show default | grep -q . && die "CT $WI_VMID HAS a default route — that is the no-WAN guarantee gone"
  info "no default route (the primary no-WAN guarantee)"

  # sshd binds 0.0.0.0 in the stock template, and on this plane 0.0.0.0 includes
  # the segment the clones are on. Nobody reaches this container over the network
  # anyway — labhost is not on vmbr-wi, so `pct exec` is the only door — which
  # makes an sshd here pure attack surface offered to anonymous visitors.
  ctexec systemctl disable --now ssh.service >/dev/null 2>&1 || true
  ctexec systemctl mask ssh.socket >/dev/null 2>&1 || true
  ctexec sh -c 'ss -lnt | grep -q ":22 "' && die "sshd is still listening in CT $WI_VMID"
  info "sshd disabled (nothing reaches this CT over the network; pct exec is the door)"
}

# --- 3. services -------------------------------------------------------------

step_services() {
  say "corpus web into CT $WI_VMID: DNS, proxy + :80 origin, search — and no OSCAR"
  local web="$HERE/../web"
  if [ "$APPLY" = 0 ]; then
    info "PLAN: install-dns.sh / install-proxy.sh / install-search.sh against CT $WI_VMID"
    info "PLAN: their labhost-side verify steps are SKIPPED — from labhost, $WI_CT_IP is CT 951"
    return
  fi
  # `install` only, never their `verify`: from labhost, 10.99.0.2 routes to the
  # RETRONET gateway over vmbr-rn, so a labhost-side probe of this address is a
  # test of the wrong machine that passes. prove-containment.sh checks these
  # services from a port of vmbr-wi, which is the only place they exist.
  RN_VMID="$WI_VMID" RN_DNS_LISTEN="$WI_CT_IP:53" RN_DNS_ANSWER="$WI_CT_IP" \
    "$web/install-dns.sh" --apply install || die "walk-in DNS install failed"
  info "wildcard DNS installed (every A -> $WI_CT_IP)"

  # RN_PROXY_REQUESTS blank turns miss-journalling OFF. On the retronet a miss
  # becomes a line in the crawl's request queue — how the corpus grows. Letting
  # an anonymous walk-in visitor steer what the museum fetches next is a hole
  # nobody asked for, and the read-only corpus mount means it could not be
  # written here anyway.
  RN_VMID="$WI_VMID" RN_PROXY_LISTEN="$WI_CT_IP:3128" RN_PROXY_ORIGIN_LISTEN="$WI_CT_IP:80" \
    RN_PROXY_CORPUS="$WI_CORPUS" RN_PROXY_REQUESTS="" \
    "$web/install-proxy.sh" --apply install || die "walk-in proxy install failed"
  info "proxy :3128 + origin :80 installed (corpus read-only, no miss journal)"

  RN_VMID="$WI_VMID" "$web/install-search.sh" --apply || die "walk-in search install failed"
  info "search.retronet installed"
}

# --- 4. verify ---------------------------------------------------------------

step_verify() {
  say "verify (labhost-side — the plane's own services are proven by prove-containment.sh)"
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
    grep -qx $'\tbridge-ports none' "$IFACE_FILE"
  probe "$WI_BRIDGE has NO address on labhost" \
    sh -c "[ -z \"\$(ip -4 -o addr show $WI_BRIDGE)\" ]"
  probe "walkin-fw rules in the kernel" /usr/local/sbin/walkin-fw verify "$WI_BRIDGE"
  probe "no labhost route to 10.99.0.0/24 via $WI_BRIDGE" \
    sh -c "! ip route show | grep -q \"dev $WI_BRIDGE\""

  probe "CT $WI_VMID running" sh -c "[ \"\$(pct status $WI_VMID)\" = 'status: running' ]"
  probe "CT $WI_VMID is single-homed on $WI_BRIDGE" \
    sh -c "[ \"\$(pct config $WI_VMID | grep -c '^net')\" = 1 ] && pct config $WI_VMID | grep -q '^net0:.*bridge=$WI_BRIDGE'"
  probe "CT $WI_VMID has NO default route" sh -c "! pct exec $WI_VMID -- ip route show default | grep -q ."
  probe "CT $WI_VMID corpus is read-only" \
    sh -c "pct config $WI_VMID | grep '^mp0:' | grep -q 'ro=1'"
  probe "CT $WI_VMID cannot write the corpus" \
    sh -c "! pct exec $WI_VMID -- touch $WI_CORPUS/.wi-write-probe"
  local u
  for u in retronet-dns retronet-proxy retronet-search; do
    probe "CT $WI_VMID $u active" sh -c "pct exec $WI_VMID -- systemctl is-active --quiet $u.service"
    probe "CT $WI_VMID $u enabled" sh -c "pct exec $WI_VMID -- systemctl is-enabled --quiet $u.service"
  done
  probe "CT $WI_VMID serves NO OSCAR (5190 unbound)" \
    sh -c "! pct exec $WI_VMID -- ss -lnt | grep -q ':5190 '"
  probe "CT $WI_VMID onboot=1 (comes back with the box)" \
    sh -c "pct config $WI_VMID | grep -q '^onboot: 1'"

  # The live retronet must be exactly as it was — this plane never touches it.
  probe "LIVE retronet: CT 951 still single-homed" \
    sh -c "[ \"\$(pct config 951 | grep -c '^net')\" = 1 ]"
  probe "LIVE retronet: OSCAR answers on 10.99.0.2:5190" nc -z -w 3 10.99.0.2 5190
  probe "LIVE retronet: corpus origin answers on 10.99.0.2:80" \
    sh -c "curl -s -o /dev/null --max-time 5 http://10.99.0.2/"
  probe "LIVE retronet: DNS answers on 10.99.0.2" \
    sh -c "dig +short +time=3 +tries=1 @10.99.0.2 anything.test | grep -q 10.99.0.2"

  [ "$fail" = 0 ] || die "verification failed"
  say "walk-in plane OK — now run prove-containment.sh, which is where it is actually proven"
}

# --- main --------------------------------------------------------------------

STEPS=()
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h | --help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    bridge | ct | services | verify) STEPS+=("$a") ;;
    *) die "unknown arg: $a (want --apply | bridge | ct | services | verify)" ;;
  esac
done
[ "${#STEPS[@]}" -gt 0 ] || STEPS=(bridge ct services verify)

need_labhost
for s in "${STEPS[@]}"; do "step_$s"; done
