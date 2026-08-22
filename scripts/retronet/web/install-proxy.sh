#!/usr/bin/env bash
# install-proxy.sh — install the retronet web proxy + its systemd unit INSIDE
# the gateway CT (951). Idempotent; re-running is the repair path.
#
# RUNS ON LABHOST (needs pct). From a workstation:
#   ssh lab '/data/kernel-hive/scripts/retronet/web/install-proxy.sh --apply'
#
# Steps, each nameable on the command line, in order:
#   install  system user, dirs, /opt/retronet-proxy/{proxy.py,rn_proxy_pages.py}, the rendered
#            /etc/retronet/proxy.env, the unit — enabled and started.
#   seed     push the tiny SYNTHETIC sample corpus (example.museum) into the CT
#            so the proxy has something to serve on an empty corpus. Opt-in, so
#            a real W2-populated corpus is never touched. sites.json is only
#            written if absent.
#   verify   the acceptance checks: unit up, a corpus miss returns the period
#            404, a hit serves (if seeded), search routes to a clean 502 when W3
#            is down — and the no-upstream proof (prove-no-upstream.sh).
#
# Without --apply, install/seed only print what they would do (verify is
# read-only and always runs). Config is read from the environment, defaulting to
# the web-plane contract; the rendered file is the service's /etc/retronet/
# proxy.env. As-built: docs/lab/retronet/WEB-PROXY.md.
set -euo pipefail

RN_VMID="${RN_VMID:-951}"
RN_PROXY_LISTEN="${RN_PROXY_LISTEN:-10.99.0.2:3128}"
RN_PROXY_ORIGIN_LISTEN="${RN_PROXY_ORIGIN_LISTEN:-10.99.0.2:80}"
RN_PROXY_CORPUS="${RN_PROXY_CORPUS:-/data/retronet/corpus}"
RN_PROXY_SEARCH_HOSTS="${RN_PROXY_SEARCH_HOSTS:-search.retronet}"
RN_PROXY_SEARCH_BACKEND="${RN_PROXY_SEARCH_BACKEND:-127.0.0.1:8090}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPT_DIR="/opt/retronet-proxy"
UNIT="retronet-proxy.service"
APPLY=0

say() { printf '\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die() {
  printf 'install-proxy: %s\n' "$*" >&2
  exit 1
}

need_labhost() {
  command -v pct >/dev/null 2>&1 || die "no pct — this runs ON labhost (ssh lab '...')"
  [ "$(id -u)" = 0 ] || die "must run as root on labhost"
}

ct_running() { [ "$(pct status "$RN_VMID" 2>/dev/null)" = "status: running" ]; }
ctexec() { pct exec "$RN_VMID" -- "$@"; }

# Run a shell snippet inside the CT via a pushed file — `pct exec ... -- sh -c`
# mangles quoting badly enough to be a bug farm (same reason the gateway
# provisioner does this).
ctsh() {
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  pct push "$RN_VMID" "$tmp" /tmp/.rnp-step.sh --perms 700
  rm -f "$tmp"
  pct exec "$RN_VMID" -- /bin/bash /tmp/.rnp-step.sh
}

# proxy.env.tmpl carries @NAME@ placeholders named for the variables above.
render_env() {
  local out v
  out="$(cat "$HERE/proxy.env.tmpl")"
  for v in RN_PROXY_LISTEN RN_PROXY_ORIGIN_LISTEN RN_PROXY_CORPUS RN_PROXY_SEARCH_HOSTS RN_PROXY_SEARCH_BACKEND; do
    out="${out//@$v@/${!v}}"
  done
  printf '%s\n' "$out"
}

# --- install ----------------------------------------------------------------

step_install() {
  say "install proxy into CT $RN_VMID  (proxy $RN_PROXY_LISTEN, origin ${RN_PROXY_ORIGIN_LISTEN:-off}, corpus $RN_PROXY_CORPUS)"
  ct_running || die "CT $RN_VMID is not running — provision the gateway first (GATEWAY.md)"
  if [ "$APPLY" = 0 ]; then
    info "PLAN: create user rnproxy; $OPT_DIR/{proxy.py,rn_proxy_pages.py}; /etc/retronet/proxy.env;"
    info "PLAN: $RN_PROXY_CORPUS; install+enable+start $UNIT"
    return
  fi

  local rendered
  rendered="$(mktemp)"
  render_env >"$rendered"
  pct push "$RN_VMID" "$HERE/proxy.py" /tmp/rnp-proxy.py --perms 644
  pct push "$RN_VMID" "$HERE/rn_proxy_pages.py" /tmp/rnp-proxy-pages.py --perms 644
  pct push "$RN_VMID" "$rendered" /tmp/rnp-proxy.env --perms 644
  pct push "$RN_VMID" "$HERE/$UNIT" /tmp/rnp-proxy.service --perms 644
  rm -f "$rendered"

  ctsh <<'EOF'
set -euo pipefail
# Unprivileged service account, like the OSCAR server's `ras`. No shell, no home.
id rnproxy >/dev/null 2>&1 ||
  useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin rnproxy
install -d -o root -g root -m 0755 /opt/retronet-proxy /etc/retronet
# The corpus is served, public, static content — world-readable so the
# unprivileged service can traverse and read files era-press pushes here as root.
install -d -o root -g root -m 0755 /data/retronet
# /data/retronet/corpus may be a bind-mount from the host corpus volume — an
# unprivileged CT cannot chown a host-owned mount, so `install -d` on it fails
# fatally. Create it only on a fresh install (no mount); leave an existing dir as-is.
[ -d /data/retronet/corpus ] || mkdir -p /data/retronet/corpus
install -o root -g root -m 0755 /tmp/rnp-proxy.py /opt/retronet-proxy/proxy.py
install -o root -g root -m 0644 /tmp/rnp-proxy-pages.py /opt/retronet-proxy/rn_proxy_pages.py
install -o root -g root -m 0644 /tmp/rnp-proxy.env /etc/retronet/proxy.env
install -o root -g root -m 0644 /tmp/rnp-proxy.service /etc/systemd/system/retronet-proxy.service
rm -f /tmp/rnp-proxy.py /tmp/rnp-proxy-pages.py /tmp/rnp-proxy.env /tmp/rnp-proxy.service /tmp/.rnp-step.sh
systemctl daemon-reload
systemctl enable --now retronet-proxy.service
systemctl restart retronet-proxy.service
EOF

  local hostport="${RN_PROXY_LISTEN}"
  info "waiting for the proxy listener on $hostport"
  local h="${hostport%:*}" p="${hostport##*:}"
  local i
  for i in $(seq 20); do
    nc -z -w 2 "$h" "$p" >/dev/null 2>&1 && break
    sleep 0.5
  done
  nc -z -w 2 "$h" "$p" >/dev/null 2>&1 || die "proxy did not come up on $hostport"
  info "listening on $hostport"
}

# --- seed (opt-in synthetic sample) -----------------------------------------

step_seed() {
  say "seed synthetic sample corpus (example.museum) into CT $RN_VMID"
  ct_running || die "CT $RN_VMID is not running"
  if [ "$APPLY" = 0 ]; then
    info "PLAN: push $HERE/sample-corpus/example.museum -> $RN_PROXY_CORPUS/example.museum"
    info "PLAN: write $RN_PROXY_CORPUS/sites.json only if absent"
    return
  fi
  local tgz
  tgz="$(mktemp --suffix=.tgz)"
  tar -C "$HERE/sample-corpus" -czf "$tgz" example.museum
  pct push "$RN_VMID" "$tgz" /tmp/rnp-sample.tgz --perms 644
  pct push "$RN_VMID" "$HERE/sample-corpus/sites.json" /tmp/rnp-sites.json --perms 644
  rm -f "$tgz"
  ctsh <<'EOF'
set -euo pipefail
install -d -m 0755 /data/retronet/corpus
tar -C /data/retronet/corpus -xzf /tmp/rnp-sample.tgz
# Never clobber a manifest a populated corpus already has — the sample's is only
# a seed for an empty one.
[ -f /data/retronet/corpus/sites.json ] ||
  install -m 0644 /tmp/rnp-sites.json /data/retronet/corpus/sites.json
chmod -R a+rX /data/retronet/corpus
rm -f /tmp/rnp-sample.tgz /tmp/rnp-sites.json /tmp/.rnp-step.sh
EOF
  info "seeded example.museum (remove it once real sites are pushed)"
}

# --- verify -----------------------------------------------------------------

step_verify() {
  say "verify (CT $RN_VMID)"
  local fail=0 h p
  h="${RN_PROXY_LISTEN%:*}"
  p="${RN_PROXY_LISTEN##*:}"
  probe() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then info "PASS  $label"; else
      info "FAIL  $label"
      fail=1
    fi
  }

  probe "proxy unit active" ctexec systemctl is-active --quiet "$UNIT"
  probe "proxy unit enabled (starts with the CT)" ctexec systemctl is-enabled --quiet "$UNIT"
  probe "listener $RN_PROXY_LISTEN open" nc -z -w 3 "$h" "$p"

  # Functional, through the proxy from labhost (curl is absent in the CT).
  local code body
  code="$(curl -s -o /dev/null -w '%{http_code}' -x "$RN_PROXY_LISTEN" http://nope.invalid/ || true)"
  body="$(curl -s -x "$RN_PROXY_LISTEN" http://nope.invalid/ || true)"
  if [ "$code" = 404 ] && printf '%s' "$body" | grep -qi "museum"; then
    info "PASS  miss http://nope.invalid/ -> period 404"
  else
    info "FAIL  miss http://nope.invalid/ -> got HTTP $code"
    fail=1
  fi

  if ctexec test -f /data/retronet/corpus/example.museum/index.html; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -x "$RN_PROXY_LISTEN" http://example.museum/ || true)"
    if [ "$code" = 200 ]; then info "PASS  hit  http://example.museum/ -> 200"; else
      info "FAIL  hit  http://example.museum/ -> HTTP $code"
      fail=1
    fi
  else
    info "SKIP  hit test: no sample seeded (run: install-proxy.sh --apply seed)"
  fi

  # Search routing: with W3 down this must be a clean period 502, not a hang.
  code="$(curl -s -o /dev/null -w '%{http_code}' -x "$RN_PROXY_LISTEN" http://search.retronet/ || true)"
  case "$code" in
    502) info "PASS  search.retronet routes -> 502 (W3 offline, clean)" ;;
    200) info "PASS  search.retronet routes -> 200 (W3 is up)" ;;
    *)
      info "FAIL  search.retronet routing -> HTTP $code"
      fail=1
      ;;
  esac

  # The no-upstream proof: same code, straced locally on labhost (the CT has no
  # strace, and the property is a property of the code, identical everywhere).
  say "no-upstream proof (prove-no-upstream.sh, on labhost)"
  if "$HERE/prove-no-upstream.sh"; then info "PASS  no outbound socket to any non-loopback address"; else
    info "FAIL  no-upstream proof"
    fail=1
  fi

  [ "$fail" = 0 ] || die "verification failed"
  say "web proxy OK — $RN_PROXY_LISTEN"
}

# --- main -------------------------------------------------------------------

STEPS=()
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h | --help)
      sed -n '2,29p' "$0"
      exit 0
      ;;
    install | seed | verify) STEPS+=("$a") ;;
    *) die "unknown arg: $a (want --apply | install | seed | verify)" ;;
  esac
done
[ "${#STEPS[@]}" -gt 0 ] || STEPS=(install verify)

need_labhost
for s in "${STEPS[@]}"; do "step_$s"; done
