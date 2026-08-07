#!/usr/bin/env bash
# mobile-netem — emulate the user's mobile 5G + WireGuard path for STREAMHOST
# TRAFFIC ONLY between the lab box and dev container CT950 (osgallery-dev,
# 192.0.2.11). Chrome DevTools throttling cannot shape WebTransport/QUIC,
# so the shaping happens here, in the kernel, on the box.
#
# SOURCE OF TRUTH: scripts/dev/mobile-netem.sh (osgallery repo)
# LIVE COPY:       /usr/local/bin/mobile-netem (on the lab box)
# These two files MUST stay byte-identical (same rule as scripts/labctl).
# The script runs ON THE BOX as root:  ssh lab 'mobile-netem on|off|status'
#
# EMULATED PROFILE — measured phone baseline (fast.com over 5G + WireGuard,
# 2026-07-17): 44 Mbps down / 29 Mbps up, 42 ms unloaded latency, ~510 ms
# loaded latency (bufferbloat), streamhost stream RTT ~93 ms. Emulation:
#   * +45 ms delay each way  -> +90 ms RTT on matched flows
#   * 40 Mbit down / 29 Mbit up HTB shaping
#   * DEEP bottleneck queue: netem limit 1800 pkts down (~500 ms at 40 Mbit),
#     600 pkts up — reproduces the loaded-latency bufferbloat.
#
# SCOPE / SAFETY:
#   * qdiscs attach ONLY to CT950's veth (veth950i0) and one dedicated ifb
#     (ifbmn950) — never vmbr*/eth*/other veths (hard-guarded below).
#   * Only streamhost flows are matched: tile WebTransport UDP ports
#     (SH_PORT= in /data/vms/streamhost/tiles/*/tile.env, discovered at `on`
#     time) + TCP 8443 (SPA https server). Everything else — ssh, mosh,
#     ping, other guests — rides the HTB default class at 10 Gbit (downlink)
#     or is never redirected to the ifb (uplink).
#   * `on` arms a fail-safe: transient systemd timer runs `mobile-netem off`
#     after MN_AUTOOFF (default 4h). `on`/`off` are idempotent both ways.
#
# Usage:  mobile-netem on | off | status
# Env overrides:
#   MN_RATE_DOWN=40mbit  MN_RATE_UP=29mbit  MN_DELAY=45ms
#   MN_QUEUE_DOWN=1800   MN_QUEUE_UP=600    (netem limit, packets)
#   MN_CTID=950  MN_BOX_IP=192.0.2.10  MN_AUTOOFF=4h
set -euo pipefail

CTID="${MN_CTID:-950}"
VETH="veth${CTID}i0"
IFB="ifbmn${CTID}"
BOX_IP="${MN_BOX_IP:-${SH_HOST_IP:-192.0.2.10}}"
RATE_DOWN="${MN_RATE_DOWN:-40mbit}"
RATE_UP="${MN_RATE_UP:-29mbit}"
DELAY="${MN_DELAY:-45ms}"
QUEUE_DOWN="${MN_QUEUE_DOWN:-1800}"
QUEUE_UP="${MN_QUEUE_UP:-600}"
AUTOOFF="${MN_AUTOOFF:-4h}"
TILES_DIR=/data/vms/streamhost/tiles
SPA_TCP_PORT=8443
AUTOOFF_UNIT=mobile-netem-autooff

die() {
  echo "mobile-netem: ERROR: $*" >&2
  exit 1
}

# Hard guard: this script may only ever touch CT950's veth and its own ifb.
guard_iface() {
  case "$1" in
    "veth${CTID}i0" | "ifbmn${CTID}") ;;
    *) die "refusing to touch interface '$1' (only ${VETH} / ${IFB} allowed)" ;;
  esac
}

discover_ports() {
  grep -h '^SH_PORT=' "$TILES_DIR"/*/tile.env 2>/dev/null |
    cut -d= -f2 | grep -E '^[0-9]+$' | sort -un
}

# Emit the whole tc program as one `tc -batch` file: atomic error detection
# (tc aborts on the first failing line with a nonzero exit).
build_batch() {
  local p
  # Downlink: box -> CT950 = veth egress. Default class 99 = passthrough.
  echo "qdisc add dev $VETH root handle 1: htb default 99"
  echo "class add dev $VETH parent 1: classid 1:99 htb rate 10gbit quantum 200000"
  echo "class add dev $VETH parent 1: classid 1:10 htb rate $RATE_DOWN ceil $RATE_DOWN quantum 60000"
  echo "qdisc add dev $VETH parent 1:10 handle 10: netem delay $DELAY limit $QUEUE_DOWN"
  for p in "${PORTS[@]}"; do
    echo "filter add dev $VETH parent 1: protocol ip prio 1 u32 match ip src $BOX_IP/32 match ip protocol 17 0xff match ip sport $p 0xffff flowid 1:10"
  done
  echo "filter add dev $VETH parent 1: protocol ip prio 1 u32 match ip src $BOX_IP/32 match ip protocol 6 0xff match ip sport $SPA_TCP_PORT 0xffff flowid 1:10"
  # Uplink: CT950 -> box = veth ingress; ONLY matched flows are redirected to
  # the ifb, whose single shaped class throttles everything it receives.
  echo "qdisc add dev $VETH handle ffff: ingress"
  for p in "${PORTS[@]}"; do
    echo "filter add dev $VETH parent ffff: protocol ip prio 1 u32 match ip dst $BOX_IP/32 match ip protocol 17 0xff match ip dport $p 0xffff action mirred egress redirect dev $IFB"
  done
  echo "filter add dev $VETH parent ffff: protocol ip prio 1 u32 match ip dst $BOX_IP/32 match ip protocol 6 0xff match ip dport $SPA_TCP_PORT 0xffff action mirred egress redirect dev $IFB"
  echo "qdisc add dev $IFB root handle 1: htb default 10"
  echo "class add dev $IFB parent 1: classid 1:10 htb rate $RATE_UP ceil $RATE_UP quantum 60000"
  echo "qdisc add dev $IFB parent 1:10 handle 10: netem delay $DELAY limit $QUEUE_UP"
}

teardown() {
  guard_iface "$VETH"
  guard_iface "$IFB"
  tc qdisc del dev "$VETH" root 2>/dev/null || true
  tc qdisc del dev "$VETH" ingress 2>/dev/null || true
  ip link del "$IFB" 2>/dev/null || true
}

setup() {
  local batch
  guard_iface "$VETH"
  guard_iface "$IFB"
  ip link add "$IFB" type ifb || return 1
  ip link set "$IFB" up || return 1
  batch=$(mktemp /tmp/mobile-netem.XXXXXX) || return 1
  build_batch >"$batch" || return 1
  if ! tc -batch "$batch"; then
    rm -f "$batch"
    return 1
  fi
  rm -f "$batch"
}

disarm_autooff() {
  systemctl stop "${AUTOOFF_UNIT}.timer" 2>/dev/null || true
  systemctl reset-failed "${AUTOOFF_UNIT}.service" "${AUTOOFF_UNIT}.timer" 2>/dev/null || true
}

arm_autooff() {
  disarm_autooff
  systemd-run --on-active="$AUTOOFF" --collect --unit="$AUTOOFF_UNIT" \
    /usr/local/bin/mobile-netem off ||
    echo "mobile-netem: WARNING: fail-safe auto-off timer not armed" >&2
}

cmd_on() {
  ip link show "$VETH" >/dev/null 2>&1 || die "$VETH does not exist (CT${CTID} down?)"
  mapfile -t PORTS < <(discover_ports)
  [ "${#PORTS[@]}" -ge 1 ] || die "no SH_PORT= found under $TILES_DIR/*/tile.env"
  modprobe ifb numifbs=0 2>/dev/null || true
  teardown # idempotent: always start from a clean slate
  if ! setup; then
    echo "mobile-netem: setup failed — rolling back and retrying once" >&2
    teardown
    if ! setup; then
      teardown
      die "setup failed twice; everything rolled back (state = off)"
    fi
  fi
  arm_autooff
  echo "mobile-netem: ON  ($VETH + $IFB)  down=$RATE_DOWN up=$RATE_UP delay=${DELAY}/way queue=${QUEUE_DOWN}/${QUEUE_UP}pkts"
  echo "mobile-netem: matched ports: udp ${PORTS[*]} + tcp $SPA_TCP_PORT (auto-off in $AUTOOFF)"
}

cmd_off() {
  teardown
  disarm_autooff
  echo "mobile-netem: OFF ($VETH clean, $IFB removed, auto-off timer disarmed)"
}

cmd_status() {
  local state=OFF
  tc qdisc show dev "$VETH" 2>/dev/null | grep -q '^qdisc htb 1:' && state=ON
  echo "=== mobile-netem: $state ==="
  echo "--- $VETH egress (downlink box->CT${CTID}) ---"
  tc -s qdisc show dev "$VETH"
  tc -s class show dev "$VETH"
  echo "downlink filters: $(tc filter show dev "$VETH" 2>/dev/null | grep -c 'flowid 1:10') -> class 1:10"
  echo "--- $VETH ingress -> $IFB (uplink CT${CTID}->box) ---"
  if ip link show "$IFB" >/dev/null 2>&1; then
    tc -s qdisc show dev "$IFB"
    tc -s class show dev "$IFB"
    tc -s filter show dev "$VETH" ingress 2>/dev/null |
      awk '/^\tSent/ {b += $2; p += $4} END {printf "uplink redirect actions: %d pkts, %d bytes\n", p, b}'
  else
    echo "(ifb $IFB absent)"
  fi
  echo "--- fail-safe ---"
  systemctl list-timers --no-pager --no-legend "${AUTOOFF_UNIT}.timer" 2>/dev/null |
    grep . || echo "auto-off timer: not armed"
}

case "${1:-}" in
  on) cmd_on ;;
  off) cmd_off ;;
  status) cmd_status ;;
  *)
    echo "usage: mobile-netem on|off|status   (see header for env overrides)" >&2
    exit 2
    ;;
esac
