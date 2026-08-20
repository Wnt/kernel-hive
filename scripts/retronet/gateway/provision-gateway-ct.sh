#!/usr/bin/env bash
# provision-gateway-ct.sh — build the retronet gateway from nothing.
#
# RUNS ON LABHOST (needs pct/ip/iptables). From a workstation:
#   ssh lab '/data/kernel-hive/scripts/retronet/gateway/provision-gateway-ct.sh'
#
# Every step is idempotent, so re-running is the repair path as well as the
# build path. Steps, in order, and each may be named on the command line:
#
#   bridge    an uplink-less labhost bridge (vmbr-rn, 10.99.0.1/24) plus the
#             firewall isolation that makes "no WAN" a property of the box.
#   ct        an UNPRIVILEGED Debian CT with one NIC on that bridge, a static
#             address and NO default route — the primary no-WAN guarantee.
#   install   Open OSCAR Server from its pinned upstream release tarball,
#             fetched by the HOST (which has internet) and pushed in. The CT
#             can never reach GitHub, so it can never self-update — that is
#             the point, and it is why the version is pinned here.
#   accounts  the ICQ UINs, created through the server's management API.
#   verify    the acceptance checks, including the proof that there is no WAN.
#
# Contract and as-built detail: docs/lab/retronet/GATEWAY.md
set -euo pipefail

RN_VMID="${RN_VMID:-951}"
RN_HOSTNAME="${RN_HOSTNAME:-retronet-gw}"
RN_BRIDGE="${RN_BRIDGE:-vmbr-rn}"
RN_HOST_IP="${RN_HOST_IP:-10.99.0.1}"
RN_CT_IP="${RN_CT_IP:-10.99.0.2}"
RN_PREFIX="${RN_PREFIX:-24}"
RN_TEMPLATE="${RN_TEMPLATE:-local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst}"
RN_STORAGE="${RN_STORAGE:-data}"
RN_DISK_GB="${RN_DISK_GB:-8}"
RN_CORES="${RN_CORES:-2}"
RN_MEM_MB="${RN_MEM_MB:-1024}"

# Listener plan — see settings.env.tmpl for why there are two OSCAR doors.
RN_OSCAR_PORT="${RN_OSCAR_PORT:-5190}"       # labhost-side clients (the bot)
RN_GUEST_PORT="${RN_GUEST_PORT:-5191}"       # slirp `guestfwd` target
RN_GUEST_ADDR="${RN_GUEST_ADDR:-10.0.2.100}" # what the station sees
RN_GUEST_ADVERTISED_PORT="${RN_GUEST_ADVERTISED_PORT:-5190}"
RN_TOC_PORT="${RN_TOC_PORT:-9898}"
RN_ICQ_LEGACY_PORT="${RN_ICQ_LEGACY_PORT:-4000}"
RN_API_PORT="${RN_API_PORT:-8080}"
RN_DB_PATH="${RN_DB_PATH:-/var/lib/ras/oscar.sqlite}"
RN_LOG_LEVEL="${RN_LOG_LEVEL:-info}"

# Pinned upstream release. "Retro AIM Server" was renamed "Open OSCAR Server"
# upstream in 2026; the binary, the config format and the ras.service name are
# continuous across the rename.
OOS_VERSION="${OOS_VERSION:-0.24.0}"
OOS_SHA256="${OOS_SHA256:-41ba8f6a01d68a7a1931c5b3b949e138d27ae0df5cfa44aa459f2710b0053dfb}"
OOS_URL="${OOS_URL:-https://github.com/mk6i/open-oscar-server/releases/download/v${OOS_VERSION}/open_oscar_server.${OOS_VERSION}.linux.x86_64.tar.gz}"
RN_CACHE="${RN_CACHE:-/data/retronet/dist}"

# Where the generated passwords are mirrored for lab tooling (the bot reads
# them from here). Gitignored; never committed. The CT's own
# /etc/ras/accounts.env is the other copy and the one the server trusts.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"

# The PoC plan asked for 1000 and 9898. Neither is a legal ICQ UIN: Mirabilis
# reserved everything below 10000, and the server enforces 10000-2147483646
# (upstream ErrICQUINInvalidFormat) — POST /user answers 400, not a warning. The
# planned numbers are shifted one decimal place so they stay recognisable.
RN_BOT_UIN="${RN_BOT_UIN:-10000}"
RN_PERSONA_UIN="${RN_PERSONA_UIN:-98980}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IFACE_FILE="/etc/network/interfaces.d/${RN_BRIDGE}"

say() { printf '\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die() {
  printf 'provision-gateway-ct: %s\n' "$*" >&2
  exit 1
}

need_labhost() {
  command -v pct >/dev/null 2>&1 || die "no pct — this script runs ON labhost (ssh lab '...')"
  [ "$(id -u)" = 0 ] || die "must run as root"
}

ctexec() { pct exec "$RN_VMID" -- "$@"; }

# Run a shell snippet inside the CT. `pct exec ... -- sh -c` mangles quoting
# badly enough to be a bug farm, so the snippet goes in through a file.
ctsh() {
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  pct push "$RN_VMID" "$tmp" /tmp/.rn-step.sh --perms 700
  rm -f "$tmp"
  pct exec "$RN_VMID" -- /bin/bash /tmp/.rn-step.sh
}

# --- 1. bridge --------------------------------------------------------------

step_bridge() {
  say "bridge $RN_BRIDGE ($RN_HOST_IP/$RN_PREFIX, no uplink)"

  # A collision with the real LAN would silently blackhole lab traffic, so this
  # is checked every run and not just the first.
  local net="${RN_HOST_IP%.*}.0/${RN_PREFIX}"
  if ip route show | grep -v "^$net dev $RN_BRIDGE" | grep -q "^$net "; then
    die "$net is already routed somewhere other than $RN_BRIDGE — pick another block"
  fi

  install -m 0755 "$HERE/retronet-fw.sh" /usr/local/sbin/retronet-fw

  # PVE keeps the `source /etc/network/interfaces.d/*` line in
  # /etc/network/interfaces, so a hand-managed interface belongs in a file of
  # its own: the GUI will not show it, ifupdown2 will still bring it up at boot.
  # `bridge-ports none` is what makes it uplink-less — there is no physical
  # port to leak onto.
  cat >"$IFACE_FILE" <<EOF
# retronet bridge — written by scripts/retronet/gateway/provision-gateway-ct.sh.
# NO uplink and NO gateway: this /24 exists only between labhost and the
# retronet CTs. See docs/lab/retronet/GATEWAY.md.
auto $RN_BRIDGE
iface $RN_BRIDGE inet static
	address $RN_HOST_IP/$RN_PREFIX
	bridge-ports none
	bridge-stp off
	bridge-fd 0
	post-up /usr/local/sbin/retronet-fw up $RN_BRIDGE
	post-down /usr/local/sbin/retronet-fw down $RN_BRIDGE
EOF

  # Deliberately `ifup <iface>`, never `ifreload -a`: reloading every interface
  # on a box whose only route to the world is vmbr0 is not a risk worth taking
  # to create an interface that has no dependencies.
  if ip link show "$RN_BRIDGE" >/dev/null 2>&1; then
    info "already up"
  else
    ifup "$RN_BRIDGE"
  fi
  ip -br addr show "$RN_BRIDGE" | sed 's/^/   /'
  /usr/local/sbin/retronet-fw up "$RN_BRIDGE"
  info "FORWARD isolation applied (retronet-fw status to inspect)"
}

# --- 2. container -----------------------------------------------------------

step_ct() {
  say "CT $RN_VMID ($RN_HOSTNAME, $RN_CT_IP/$RN_PREFIX on $RN_BRIDGE)"
  if pct status "$RN_VMID" >/dev/null 2>&1; then
    info "exists — reconciling config"
  else
    pct create "$RN_VMID" "$RN_TEMPLATE" \
      --hostname "$RN_HOSTNAME" \
      --unprivileged 1 \
      --cores "$RN_CORES" --memory "$RN_MEM_MB" --swap 512 \
      --rootfs "$RN_STORAGE:$RN_DISK_GB" \
      --ostype debian \
      --description "retronet gateway: offline ICQ/AIM (OSCAR) server. docs/lab/retronet/GATEWAY.md"
  fi

  # No `gw=` and no `gw6=`. That omission IS the no-WAN guarantee: with no
  # default route the CT's own stack answers "Network is unreachable" before a
  # packet is ever built. ip6=manual leaves IPv6 link-local only.
  #
  # nesting=1 is NOT about running containers in here. Debian 13 ships systemd
  # 257, which needs it to mount /tmp, /run/lock and /dev/mqueue in an
  # unprivileged CT; without it the machine boots "degraded" with three failed
  # mount units, and a service that later wants a private /tmp inherits the
  # breakage. It grants no host access — the CT stays unprivileged.
  pct set "$RN_VMID" \
    --net0 "name=eth0,bridge=$RN_BRIDGE,ip=$RN_CT_IP/$RN_PREFIX,ip6=manual,firewall=0" \
    --features nesting=1 \
    --onboot 1 \
    --nameserver "$RN_CT_IP" --searchdomain retronet.lab

  [ "$(pct status "$RN_VMID")" = "status: running" ] || pct start "$RN_VMID"
  for _ in $(seq 30); do
    ctexec true >/dev/null 2>&1 && break
    sleep 1
  done
  ctexec true >/dev/null 2>&1 || die "CT $RN_VMID did not come up"
  info "up: $(ctexec hostname) $(ctexec hostname -I)"
}

# --- 3. server --------------------------------------------------------------

# Prints ONLY the cached tarball's path on stdout — progress goes to stderr, or
# it lands inside the caller's `$( )` and gets handed to `pct push` as a
# filename.
fetch_release() {
  mkdir -p "$RN_CACHE"
  local tgz="$RN_CACHE/open_oscar_server-${OOS_VERSION}.linux.x86_64.tar.gz"
  if ! [ -f "$tgz" ] || ! echo "$OOS_SHA256  $tgz" | sha256sum -c --status; then
    info "fetching $OOS_URL" >&2
    curl -fsSL --max-time 300 -o "$tgz.part" "$OOS_URL"
    mv "$tgz.part" "$tgz"
  fi
  echo "$OOS_SHA256  $tgz" | sha256sum -c --status ||
    die "sha256 mismatch for $tgz — refusing to install"
  echo "$tgz"
}

# settings.env.tmpl carries @NAME@ placeholders named for the variables above,
# so the substitution list is just the variable names.
render_settings() {
  local out v
  out="$(cat "$HERE/settings.env.tmpl")"
  for v in RN_OSCAR_PORT RN_GUEST_PORT RN_GUEST_ADDR RN_GUEST_ADVERTISED_PORT \
    RN_CT_IP RN_TOC_PORT RN_ICQ_LEGACY_PORT RN_API_PORT RN_DB_PATH RN_LOG_LEVEL; do
    out="${out//@$v@/${!v}}"
  done
  printf '%s\n' "$out"
}

step_install() {
  say "Open OSCAR Server $OOS_VERSION into CT $RN_VMID"
  local tgz
  tgz="$(fetch_release)"
  # `pct push` prints "failed to open ... for reading" and STILL exits 0 for a
  # source file that is not there, so set -e will not catch it. Check first.
  [ -f "$tgz" ] || die "no tarball at '$tgz'"

  pct push "$RN_VMID" "$tgz" /tmp/oos.tar.gz --perms 600
  local rendered unit
  rendered="$(mktemp)"
  unit="$HERE/retronet-oscar.service"
  render_settings >"$rendered"
  pct push "$RN_VMID" "$rendered" /tmp/settings.env --perms 600
  pct push "$RN_VMID" "$unit" /tmp/retronet-oscar.service --perms 644
  pct push "$RN_VMID" "$HERE/rn-tool.py" /tmp/rn-tool.py --perms 644
  rm -f "$rendered"

  ctsh <<'EOF'
set -euo pipefail
id ras >/dev/null 2>&1 || useradd --system --home-dir /var/lib/ras --shell /usr/sbin/nologin ras
install -d -o root -g root -m 0755 /opt/ras /etc/ras
install -d -o ras -g ras -m 0750 /var/lib/ras
tmp="$(mktemp -d)"
tar -xzf /tmp/oos.tar.gz -C "$tmp"
bin="$(find "$tmp" -type f -name open_oscar_server | head -1)"
[ -n "$bin" ] || { echo "no open_oscar_server in tarball" >&2; exit 1; }
install -m 0755 "$bin" /opt/ras/open_oscar_server
find "$tmp" -type f -name LICENSE -exec install -m 0644 {} /opt/ras/LICENSE \;
rm -rf "$tmp" /tmp/oos.tar.gz
install -o root -g ras -m 0640 /tmp/settings.env /etc/ras/settings.env
install -m 0644 /tmp/retronet-oscar.service /etc/systemd/system/retronet-oscar.service
install -m 0755 /tmp/rn-tool.py /opt/ras/rn-tool.py
rm -f /tmp/settings.env /tmp/retronet-oscar.service /tmp/rn-tool.py /tmp/.rn-step.sh
systemctl daemon-reload
systemctl enable --now retronet-oscar.service
systemctl restart retronet-oscar.service
# The Debian "standard" template starts postfix. On a machine with no route off
# its own /24 it can never deliver anything; it is a daemon on the retronet's
# only shared surface, doing nothing. Off it goes.
systemctl disable --now postfix 2>/dev/null || true
/opt/ras/open_oscar_server -version
EOF
  info "waiting for the OSCAR listener"
  for _ in $(seq 30); do
    ctexec /bin/bash -c "exec 3<>/dev/tcp/127.0.0.1/$RN_OSCAR_PORT" >/dev/null 2>&1 && break
    sleep 1
  done
}

# --- 4. accounts ------------------------------------------------------------

# Read a key from the mirror if it is already there, so a re-run repairs the
# server without rotating a password the bot and the station are already using.
existing_pass() {
  [ -f "$RN_LOCAL_ENV" ] || return 0
  sed -n "s/^$1=//p" "$RN_LOCAL_ENV" | tail -1
}

# EXACTLY 8 characters, lowercase alnum. The server validates ICQ passwords at
# 6-8 characters (upstream state.validateICQPassword, mirroring what era clients
# accepted), and era clients mangle anything outside [a-z0-9]. A 12-character
# password here would be rejected by the API, not silently truncated. Four
# random bytes rendered as hex is exactly 8 characters from [0-9a-f] with no
# filtering step — and no `tr | head` pipeline, which dies of SIGPIPE under
# `set -o pipefail` the moment head has its 8 bytes.
gen_pass() { od -An -tx1 -N4 /dev/urandom | tr -d ' \n'; }

# rntool runs the CT-local helper. It is Python because the CT has no curl and
# no way to obtain one — see rn-tool.py's own header.
rntool() { ctexec python3 /opt/ras/rn-tool.py "$@"; }

ensure_user() {
  local uin="$1" pass="$2"
  rntool user-set "$uin" "$pass" | sed 's/^/   /' ||
    die "could not create or update UIN $uin"
}

mirror_key() {
  local key="$1" val="$2"
  touch "$RN_LOCAL_ENV"
  chmod 0600 "$RN_LOCAL_ENV"
  if grep -q "^$key=" "$RN_LOCAL_ENV"; then
    sed -i "s|^$key=.*|$key=$val|" "$RN_LOCAL_ENV"
  else
    printf '%s=%s\n' "$key" "$val" >>"$RN_LOCAL_ENV"
  fi
}

step_accounts() {
  say "accounts: bot UIN $RN_BOT_UIN, persona UIN $RN_PERSONA_UIN"
  local botpass personapass
  botpass="$(existing_pass RETRONET_ICQ_BOT_PASS)"
  personapass="$(existing_pass RETRONET_ICQ_PERSONA_PASS)"
  [ -n "$botpass" ] || botpass="$(gen_pass)"
  [ -n "$personapass" ] || personapass="$(gen_pass)"

  ensure_user "$RN_BOT_UIN" "$botpass"
  ensure_user "$RN_PERSONA_UIN" "$personapass"

  # Copy 1: inside the CT, root-only. This is the copy that matches the server.
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# retronet ICQ accounts — written by provision-gateway-ct.sh. NEVER commit.
RETRONET_ICQ_HOST=$RN_CT_IP
RETRONET_ICQ_PORT=$RN_OSCAR_PORT
RETRONET_ICQ_BOT_UIN=$RN_BOT_UIN
RETRONET_ICQ_BOT_PASS=$botpass
RETRONET_ICQ_PERSONA_UIN=$RN_PERSONA_UIN
RETRONET_ICQ_PERSONA_PASS=$personapass
EOF
  pct push "$RN_VMID" "$tmp" /etc/ras/accounts.env --perms 600
  rm -f "$tmp"

  # Copy 2: labhost's gitignored registry/local.env, where the bot and any
  # other lab tooling look. Same keys, same values.
  if [ -e "$(dirname "$RN_LOCAL_ENV")" ]; then
    mirror_key RETRONET_ICQ_HOST "$RN_CT_IP"
    mirror_key RETRONET_ICQ_PORT "$RN_OSCAR_PORT"
    mirror_key RETRONET_ICQ_BOT_UIN "$RN_BOT_UIN"
    mirror_key RETRONET_ICQ_BOT_PASS "$botpass"
    mirror_key RETRONET_ICQ_PERSONA_UIN "$RN_PERSONA_UIN"
    mirror_key RETRONET_ICQ_PERSONA_PASS "$personapass"
    info "mirrored to $RN_LOCAL_ENV (gitignored)"
  else
    info "skipped mirror: $(dirname "$RN_LOCAL_ENV") absent"
  fi
}

# --- 5. verify --------------------------------------------------------------

step_verify() {
  say "verify"
  local fail=0
  probe() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
      info "PASS  $label"
    else
      info "FAIL  $label"
      fail=1
    fi
  }

  probe "labhost -> $RN_CT_IP:$RN_OSCAR_PORT (OSCAR, retronet door)" nc -z -w 3 "$RN_CT_IP" "$RN_OSCAR_PORT"
  probe "labhost -> $RN_CT_IP:$RN_GUEST_PORT (OSCAR, slirp door)" nc -z -w 3 "$RN_CT_IP" "$RN_GUEST_PORT"
  probe "labhost -> $RN_CT_IP:$RN_TOC_PORT (TOC)" nc -z -w 3 "$RN_CT_IP" "$RN_TOC_PORT"
  probe "server unit active" ctexec systemctl is-active --quiet retronet-oscar.service
  probe "server unit enabled (starts with the CT)" ctexec systemctl is-enabled --quiet retronet-oscar.service
  probe "CT onboot=1 (starts with the box)" grep -qx 'onboot: 1' "/etc/pve/lxc/$RN_VMID.conf"

  # The no-WAN proof, run from INSIDE the CT: no default route in the kernel
  # table, and three well-known internet addresses dialled by IP (so a missing
  # resolver can never be mistaken for isolation). rn-tool prints each verdict.
  say "no-WAN proof (from inside CT $RN_VMID)"
  rntool wan-probe | sed 's/^/   /' || fail=1

  # A real sign-on, not a database row: the full OSCAR BUCP handshake against
  # the live listener with the recorded password.
  say "sign-on proof"
  local botpass personapass
  botpass="$(existing_pass RETRONET_ICQ_BOT_PASS)"
  personapass="$(existing_pass RETRONET_ICQ_PERSONA_PASS)"
  signon() { python3 "$HERE/rn-tool.py" login "$RN_CT_IP" "$@" | sed 's/^/   /' || fail=1; }
  signon "$RN_OSCAR_PORT" "$RN_BOT_UIN" "$botpass"
  signon "$RN_OSCAR_PORT" "$RN_PERSONA_UIN" "$personapass"
  # The slirp door must hand back the address the STATION can reach, not this
  # one. Checking it from labhost is the only place the mismatch is cheap.
  signon "$RN_GUEST_PORT" "$RN_PERSONA_UIN" "$personapass"

  [ "$fail" = 0 ] || die "verification failed"
  say "gateway OK — $RN_CT_IP:$RN_OSCAR_PORT"
}

# --- main -------------------------------------------------------------------

need_labhost
STEPS=("$@")
[ "${#STEPS[@]}" -gt 0 ] || STEPS=(bridge ct install accounts verify)
for s in "${STEPS[@]}"; do
  case "$s" in
    bridge | ct | install | accounts | verify) "step_$s" ;;
    *)
      echo "usage: provision-gateway-ct.sh [bridge|ct|install|accounts|verify ...]" >&2
      exit 2
      ;;
  esac
done
