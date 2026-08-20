#!/usr/bin/env bash
# install-dns.sh — install the retronet wildcard DNS resolver + its systemd unit
# INSIDE the gateway CT (951). Idempotent; re-running is the repair path.
#
# RUNS ON LABHOST (needs pct). From a workstation:
#   ssh lab '/data/kernel-hive/scripts/retronet/web/install-dns.sh --apply'
#
# Steps, each nameable on the command line, in order:
#   install  system user rndns, /opt/retronet-dns/dns.py, the rendered
#            /etc/retronet/dns.env, the unit — enabled and started.
#   verify   the acceptance checks: unit up + enabled, and a UDP and a TCP query
#            for arbitrary names both answer with the gateway address (proving
#            the wildcard), while an AAAA query returns NODATA (a client falls
#            back to A). Queried from labhost over the bridge with dns.py's own
#            test client (the CT has no dig).
#
# Without --apply, install only prints what it would do (verify is read-only and
# always runs). Config is read from the environment, defaulting to the web-plane
# contract; the rendered file is the service's /etc/retronet/dns.env.
# As-built: docs/lab/retronet/WEB-PROXY.md.
set -euo pipefail

RN_VMID="${RN_VMID:-951}"
RN_DNS_LISTEN="${RN_DNS_LISTEN:-10.99.0.2:53}"
RN_DNS_ANSWER="${RN_DNS_ANSWER:-10.99.0.2}"
RN_DNS_TTL="${RN_DNS_TTL:-300}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPT_DIR="/opt/retronet-dns"
UNIT="retronet-dns.service"
APPLY=0

say() { printf '\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die() {
  printf 'install-dns: %s\n' "$*" >&2
  exit 1
}

need_labhost() {
  command -v pct >/dev/null 2>&1 || die "no pct — this runs ON labhost (ssh lab '...')"
  [ "$(id -u)" = 0 ] || die "must run as root on labhost"
}

ct_running() { [ "$(pct status "$RN_VMID" 2>/dev/null)" = "status: running" ]; }
ctexec() { pct exec "$RN_VMID" -- "$@"; }

# Run a shell snippet inside the CT via a pushed file — `pct exec ... -- sh -c`
# mangles quoting badly enough to be a bug farm.
ctsh() {
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  pct push "$RN_VMID" "$tmp" /tmp/.rnd-step.sh --perms 700
  rm -f "$tmp"
  pct exec "$RN_VMID" -- /bin/bash /tmp/.rnd-step.sh
}

# dns.env.tmpl carries @NAME@ placeholders named for the variables above.
render_env() {
  local out v
  out="$(cat "$HERE/dns.env.tmpl")"
  for v in RN_DNS_LISTEN RN_DNS_ANSWER RN_DNS_TTL; do
    out="${out//@$v@/${!v}}"
  done
  printf '%s\n' "$out"
}

# --- install ----------------------------------------------------------------

step_install() {
  say "install DNS into CT $RN_VMID  (listen $RN_DNS_LISTEN, every A -> $RN_DNS_ANSWER)"
  ct_running || die "CT $RN_VMID is not running — provision the gateway first (GATEWAY.md)"
  if [ "$APPLY" = 0 ]; then
    info "PLAN: create user rndns; $OPT_DIR/dns.py; /etc/retronet/dns.env;"
    info "PLAN: install+enable+start $UNIT (CAP_NET_BIND_SERVICE for :53)"
    return
  fi

  local rendered
  rendered="$(mktemp)"
  render_env >"$rendered"
  pct push "$RN_VMID" "$HERE/dns.py" /tmp/rnd-dns.py --perms 644
  pct push "$RN_VMID" "$rendered" /tmp/rnd-dns.env --perms 644
  pct push "$RN_VMID" "$HERE/$UNIT" /tmp/rnd-dns.service --perms 644
  rm -f "$rendered"

  ctsh <<'EOF'
set -euo pipefail
# Unprivileged service account, like the proxy's rnproxy. No shell, no home.
id rndns >/dev/null 2>&1 ||
  useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin rndns
install -d -o root -g root -m 0755 /opt/retronet-dns /etc/retronet
install -o root -g root -m 0755 /tmp/rnd-dns.py /opt/retronet-dns/dns.py
install -o root -g root -m 0644 /tmp/rnd-dns.env /etc/retronet/dns.env
install -o root -g root -m 0644 /tmp/rnd-dns.service /etc/systemd/system/retronet-dns.service
rm -f /tmp/rnd-dns.py /tmp/rnd-dns.env /tmp/rnd-dns.service /tmp/.rnd-step.sh
systemctl daemon-reload
systemctl enable --now retronet-dns.service
systemctl restart retronet-dns.service
EOF

  local h="${RN_DNS_LISTEN%:*}" p="${RN_DNS_LISTEN##*:}"
  info "waiting for the resolver on $h:$p"
  local i
  for i in $(seq 20); do
    python3 "$HERE/dns.py" query rn-liveness-probe.test --server "$RN_DNS_LISTEN" >/dev/null 2>&1 && break
    sleep 0.5
  done
  python3 "$HERE/dns.py" query rn-liveness-probe.test --server "$RN_DNS_LISTEN" >/dev/null 2>&1 ||
    die "resolver did not answer on $RN_DNS_LISTEN"
  info "answering on $RN_DNS_LISTEN"
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

  probe "dns unit active" ctexec systemctl is-active --quiet "$UNIT"
  probe "dns unit enabled (starts with the CT)" ctexec systemctl is-enabled --quiet "$UNIT"

  # Wildcard: two arbitrary names must both answer with the gateway address,
  # over UDP and over TCP. dns.py's client prints "<name> ... -> ['<ip>']".
  local out
  for name in spacejam.com totally.made.up.example; do
    out="$(python3 "$HERE/dns.py" query "$name" --server "$RN_DNS_LISTEN" 2>/dev/null || true)"
    if printf '%s' "$out" | grep -q "'$RN_DNS_ANSWER'"; then
      info "PASS  udp A $name -> $RN_DNS_ANSWER"
    else
      info "FAIL  udp A $name -> $out"
      fail=1
    fi
  done
  out="$(python3 "$HERE/dns.py" query search.retronet --server "$RN_DNS_LISTEN" --tcp 2>/dev/null || true)"
  if printf '%s' "$out" | grep -q "'$RN_DNS_ANSWER'"; then
    info "PASS  tcp A search.retronet -> $RN_DNS_ANSWER"
  else
    info "FAIL  tcp A search.retronet -> $out"
    fail=1
  fi
  # AAAA must be NODATA (no A record), so an IPv4-only client falls back to A.
  out="$(python3 "$HERE/dns.py" query spacejam.com --server "$RN_DNS_LISTEN" --type AAAA 2>/dev/null || true)"
  if printf '%s' "$out" | grep -q "no A record"; then
    info "PASS  aaaa spacejam.com -> NODATA (falls back to A)"
  else
    info "FAIL  aaaa spacejam.com -> $out"
    fail=1
  fi

  # The in-process wire-format selftest (no network) — the property is a
  # property of the code, identical everywhere.
  if python3 "$HERE/dns.py" selftest >/dev/null 2>&1; then
    info "PASS  wire-format selftest"
  else
    info "FAIL  wire-format selftest"
    fail=1
  fi

  [ "$fail" = 0 ] || die "verification failed"
  say "wildcard DNS OK — $RN_DNS_LISTEN, every A -> $RN_DNS_ANSWER"
}

# --- main -------------------------------------------------------------------

STEPS=()
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    install | verify) STEPS+=("$a") ;;
    *) die "unknown arg: $a (want --apply | install | verify)" ;;
  esac
done
[ "${#STEPS[@]}" -gt 0 ] || STEPS=(install verify)

need_labhost
for s in "${STEPS[@]}"; do "step_$s"; done
