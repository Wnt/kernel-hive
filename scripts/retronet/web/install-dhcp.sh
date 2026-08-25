#!/usr/bin/env bash
# install-dhcp.sh — install the retronet DHCP server + its systemd unit INSIDE
# the gateway CT (951). Idempotent; re-running is the repair path.
#
# RUNS ON LABHOST (needs pct). From a workstation:
#   ssh lab '/data/kernel-hive/scripts/retronet/web/install-dhcp.sh --apply'
#
# It hands bridged stations an IP + mask + DNS(=the gateway), and NO router
# option, so a station joins with the Windows DHCP defaults and gets no default
# route (containment). Per-MAC reservations keep known stations on a STABLE IP.
#
# Steps:
#   install  user rndhcp, /opt/retronet-dhcp/dhcp.py, rendered
#            /etc/retronet/dhcp.env, the unit — enabled and started.
#   verify   unit up + enabled; the in-process wire selftest; and a functional
#            DISCOVER->OFFER probe from labhost (best-effort — needs udp/67 free
#            on labhost) proving a pool address + DNS + NO router option.
#
# REAL MACs are box-local: reservations come from registry/local.env
# (RETRONET_DHCP_RESERVATIONS="mac=ip mac=ip"), never from the committed tree.
# Override any knob by exporting the matching RN_DHCP_* first.
# As-built: docs/lab/retronet/WEB-PROXY.md.
set -euo pipefail

RN_VMID="${RN_VMID:-951}"
RN_DHCP_LISTEN="${RN_DHCP_LISTEN:-0.0.0.0:67}"
# The retronet leg. Must match the interface the ExecStartPre broadcast route
# is added to; see dhcp.env.tmpl for why an unpinned scope is a bug here.
RN_DHCP_BIND_DEVICE="${RN_DHCP_BIND_DEVICE:-eth0}"
RN_DHCP_SERVER_ID="${RN_DHCP_SERVER_ID:-10.99.0.2}"
RN_DHCP_SUBNET_MASK="${RN_DHCP_SUBNET_MASK:-255.255.255.0}"
RN_DHCP_DNS="${RN_DHCP_DNS:-10.99.0.2}"
RN_DHCP_DOMAIN="${RN_DHCP_DOMAIN:-retronet.lab}"
RN_DHCP_POOL="${RN_DHCP_POOL:-10.99.0.100-10.99.0.200}"
RN_DHCP_LEASE="${RN_DHCP_LEASE:-3600}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPT_DIR="/opt/retronet-dhcp"
UNIT="retronet-dhcp.service"
APPLY=0

say() { printf '\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die() {
  printf 'install-dhcp: %s\n' "$*" >&2
  exit 1
}

# Reservations: env wins; else read RETRONET_DHCP_RESERVATIONS from local.env
# (this clone's, then the box's canonical one). Sourced in a subshell so
# local.env's other contents cannot leak in.
resolve_reservations() {
  [ -n "${RN_DHCP_RESERVATIONS:-}" ] && return
  local repo_root le
  repo_root="$(cd "$HERE/../../.." && pwd)"
  for le in "$repo_root/registry/local.env" /data/kernel-hive/registry/local.env; do
    if [ -f "$le" ]; then
      RN_DHCP_RESERVATIONS="$(
        # shellcheck disable=SC1090
        . "$le" 2>/dev/null
        printf '%s' "${RETRONET_DHCP_RESERVATIONS:-}"
      )"
      [ -n "$RN_DHCP_RESERVATIONS" ] && {
        info "reservations from $le"
        return
      }
    fi
  done
  RN_DHCP_RESERVATIONS=""
  info "no RETRONET_DHCP_RESERVATIONS in local.env — pool only"
}

need_labhost() {
  command -v pct >/dev/null 2>&1 || die "no pct — this runs ON labhost (ssh lab '...')"
  [ "$(id -u)" = 0 ] || die "must run as root on labhost"
}

ct_running() { [ "$(pct status "$RN_VMID" 2>/dev/null)" = "status: running" ]; }
ctexec() { pct exec "$RN_VMID" -- "$@"; }

ctsh() {
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  pct push "$RN_VMID" "$tmp" /tmp/.rnh-step.sh --perms 700
  rm -f "$tmp"
  pct exec "$RN_VMID" -- /bin/bash /tmp/.rnh-step.sh
}

render_env() {
  local out v
  out="$(cat "$HERE/dhcp.env.tmpl")"
  for v in RN_DHCP_LISTEN RN_DHCP_BIND_DEVICE RN_DHCP_SERVER_ID RN_DHCP_SUBNET_MASK RN_DHCP_DNS \
    RN_DHCP_DOMAIN RN_DHCP_POOL RN_DHCP_LEASE RN_DHCP_RESERVATIONS; do
    out="${out//@$v@/${!v}}"
  done
  printf '%s\n' "$out"
}

# --- install ----------------------------------------------------------------

step_install() {
  resolve_reservations
  say "install DHCP into CT $RN_VMID  (pool $RN_DHCP_POOL, dns $RN_DHCP_DNS, no router)"
  ct_running || die "CT $RN_VMID is not running — provision the gateway first (GATEWAY.md)"
  if [ "$APPLY" = 0 ]; then
    info "PLAN: create user rndhcp; $OPT_DIR/dhcp.py; /etc/retronet/dhcp.env;"
    info "PLAN: reservations = ${RN_DHCP_RESERVATIONS:-(none)}"
    info "PLAN: install+enable+start $UNIT (CAP_NET_BIND_SERVICE for :67)"
    return
  fi

  local rendered
  rendered="$(mktemp)"
  render_env >"$rendered"
  pct push "$RN_VMID" "$HERE/dhcp.py" /tmp/rnh-dhcp.py --perms 644
  pct push "$RN_VMID" "$rendered" /tmp/rnh-dhcp.env --perms 644
  pct push "$RN_VMID" "$HERE/$UNIT" /tmp/rnh-dhcp.service --perms 644
  rm -f "$rendered"

  ctsh <<'EOF'
set -euo pipefail
id rndhcp >/dev/null 2>&1 ||
  useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin rndhcp
install -d -o root -g root -m 0755 /opt/retronet-dhcp /etc/retronet
install -o root -g root -m 0755 /tmp/rnh-dhcp.py /opt/retronet-dhcp/dhcp.py
# dhcp.env carries no secret, but the reservations are box-local MACs — 0640.
install -o root -g rndhcp -m 0640 /tmp/rnh-dhcp.env /etc/retronet/dhcp.env
install -o root -g root -m 0644 /tmp/rnh-dhcp.service /etc/systemd/system/retronet-dhcp.service
rm -f /tmp/rnh-dhcp.py /tmp/rnh-dhcp.env /tmp/rnh-dhcp.service /tmp/.rnh-step.sh
systemctl daemon-reload
systemctl enable --now retronet-dhcp.service
systemctl restart retronet-dhcp.service
EOF
  ctexec systemctl is-active --quiet "$UNIT" || die "retronet-dhcp did not start — journalctl -u $UNIT in CT $RN_VMID"
  info "retronet-dhcp active"
}

# --- verify -----------------------------------------------------------------

step_verify() {
  say "verify (CT $RN_VMID)"
  local fail=0
  probe() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then info "PASS  $label"; else
      info "FAIL  $label"
      fail=1
    fi
  }

  probe "dhcp unit active" ctexec systemctl is-active --quiet "$UNIT"
  probe "dhcp unit enabled (starts with the CT)" ctexec systemctl is-enabled --quiet "$UNIT"
  probe "udp/67 bound in CT" ctexec bash -c "ss -lun | grep -q ':67 '"

  if python3 "$HERE/dhcp.py" selftest >/dev/null 2>&1; then
    info "PASS  wire-format selftest (reservation, no-router, pool)"
  else
    info "FAIL  wire-format selftest"
    fail=1
  fi

  # Functional DISCOVER->OFFER from labhost, posing as a relay (giaddr) so the
  # OFFER unicasts back to us. Needs udp/67 free on labhost; if not, SKIP (the
  # definitive lease proof is win98se pulling its reservation — framebuffer).
  local out
  if out="$(python3 "$HERE/dhcp.py" probe --server "$RN_DHCP_SERVER_ID" --giaddr 10.99.0.1 --mac 02:00:00:ab:cd:ef 2>&1)"; then
    if printf '%s' "$out" | grep -q "router_option=absent"; then
      info "PASS  functional: $out"
    else
      info "FAIL  functional: $out"
      fail=1
    fi
  else
    info "SKIP  functional probe (udp/67 busy on labhost?): $out"
  fi

  [ "$fail" = 0 ] || die "verification failed"
  say "DHCP OK — pool $RN_DHCP_POOL, dns $RN_DHCP_DNS, NO router option"
}

# --- main -------------------------------------------------------------------

STEPS=()
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h | --help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    install | verify) STEPS+=("$a") ;;
    *) die "unknown arg: $a (want --apply | install | verify)" ;;
  esac
done
[ "${#STEPS[@]}" -gt 0 ] || STEPS=(install verify)

need_labhost
for s in "${STEPS[@]}"; do "step_$s"; done
