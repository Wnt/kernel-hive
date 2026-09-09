#!/usr/bin/env bash
# rn-verify.sh — "is this station actually ON the retronet plane?", for one
# station or the whole fleet. Run it ON labhost:
#
#   ssh lab '/data/kernel-hive/scripts/retronet/rn-verify.sh pcbsd suse64'
#   ssh lab '/data/kernel-hive/scripts/retronet/rn-verify.sh --all'
#   ssh lab '/data/kernel-hive/scripts/retronet/rn-verify.sh --since "5 min ago" suse64'
#
# It generalises the hand-written phase-3 sweep of 2026-09-03, which carried the
# nine stations' addresses and MACs in two literal arrays. Nothing is hard-coded
# here: the address comes from the station's committed registry `retronet` block
# and the MAC from the BOX-side local.env (rule 1 — the real value never reaches
# git, so this check can only run on the box, which is where it belongs).
#
# THE FIVE THINGS IT GATES, and why each one is the check and not a proxy:
#
#   tap         the interface exists and is UP. A tap that is DOWN answers
#               nothing and looks exactly like a wedged guest.
#   master      it is enslaved to vmbr-rn specifically. A tap that exists but is
#               unenslaved is a private link to nowhere, and `ip link show` alone
#               will not tell you.
#   unit        streamhost@<id> is active. A station can be perfectly wired and
#               simply stopped — the fleet is routinely stopped or paused.
#   env-rn      the tap is NAMED in the deployed launcher or station.env. The
#               tap being up proves nothing about whether THIS station's QEMU
#               attaches to it; a renamed tap leaves an orphan up on the bridge.
#   reservation the MAC->address pair is RENDERED in CT 951's /etc/retronet/
#               dhcp.env, not merely present in local.env. Editing the ledger
#               does not install it; install-dhcp.sh does. The first guest of
#               the 2026-09-03 wave leased a pool address on exactly this gap,
#               and a pool address also escapes an IP-scoped guard chain.
#
# THE SIXTH GATE, only with `--since <timestamp>`: a FRESH ICQ login in CT 951's
# `retronet-oscar` journal, for the UIN roster.json gives this station.
#
# It exists because the client's own window lies about this, and it lied on a
# real station: after a `labctl reset` (loadvm golden) suse64's GtkICQ 0.60
# showed its contact list "Online" while the gateway answered every packet from
# it with "unknown session, NOT_CONNECTED". A restored vmstate carries a TCP
# socket the server forgot hours ago; the client keeps drawing the last state it
# knew. So the only proof a restored station is really signed in is a NEW
# `login successful uin=<uin>` line dated after the reset — AND a frame. Neither
# alone is the proof: the journal line can precede a client that then died, and
# the frame can be a painting of a dead socket.
#
#   ssh lab 'labctl reset suse64'; …wait for the wake and ~90 s more…
#   ssh lab 'rn-verify.sh --since "@<reset epoch>" suse64' && ssh lab 'labctl shot suse64'
#
# `--icq <uin>` overrides the roster lookup (a station mid-onboarding has no
# roster row yet).
#
# REPORTED BUT NOT GATED: the bridge forwarding-database entry. An fdb entry
# only exists while the guest is awake and talking, and a station with no viewer
# idle-pauses after ~2 minutes — so gating on it would fail every idle station.
# `fdb=1` is positive evidence the guest is really on the L2; `fdb=0` is not
# evidence of anything.
#
# NOT A CHECK AT ALL: pinging the guest from labhost. Containment means
# labhost-initiated traffic is precisely the traffic that IS allowed, so a reply
# says nothing about the plane, and the absence of one says nothing either.
#
# Exit 0 only if every named station passes every gate.
set -u

REPO="${KH_REPO:-/data/kernel-hive}"
STATIONS_DIR="${KH_STATIONS_DIR:-/data/vms/streamhost/stations}"
LOCAL_ENV="${KH_LOCAL_ENV:-$REPO/registry/local.env}"
BRIDGE="${RN_BRIDGE:-vmbr-rn}"
GW_CT="${RN_GW_CT:-951}"
OSCAR_UNIT="${RN_OSCAR_UNIT:-retronet-oscar}"
SINCE=""
ICQ_UIN=""

usage() {
  sed -n '2,8p' "$0" >&2
  exit 2
}

# Every station whose committed registry row declares a retronet block.
all_stations() {
  python3 - "$REPO" <<'EOF'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]) / "registry" / "stations"
for path in sorted(root.glob("*.json")):
    row = json.loads(path.read_text(encoding="utf-8"))
    if row.get("retronet"):
        print(row["id"])
EOF
}

# address<TAB>tap<TAB>guard, straight out of the registry block. `link` is prose
# of the form "tap <if> on <bridge>", the same shape stations-registry.py
# facts-live parses, so the tap name has ONE definition and not two.
station_facts() {
  python3 - "$REPO" "$1" <<'EOF'
import json, pathlib, re, sys
path = pathlib.Path(sys.argv[1]) / "registry" / "stations" / f"{sys.argv[2]}.json"
block = (json.loads(path.read_text(encoding="utf-8")).get("retronet") or {}) if path.exists() else {}
if not block:
    sys.exit(1)
link = re.search(r"tap\s+(\S+)\s+on\s+(\S+)", block.get("link", ""))
print("\t".join([block.get("address", ""), link.group(1) if link else "", block.get("guard", "")]))
EOF
}

# The station's ICQ UIN, out of roster.json — the single source for the persona.
station_uin() {
  python3 - "$REPO" "$1" <<'EOF'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]) / "scripts" / "retronet" / "icq" / "roster.json"
rows = json.loads(path.read_text(encoding="utf-8"))["stations"] if path.exists() else []
print(next((r["uin"] for r in rows if r["station"] == sys.argv[2]), ""))
EOF
}

# A login the GATEWAY itself logged after $SINCE. The OSCAR and the legacy v4/v5
# handlers word it differently ("login successful" vs "user authenticated
# successfully"); only the uin= field is common to both, so match on that first.
fresh_login() {
  local uin="$1"
  [ -n "$uin" ] || return 1
  pct exec "$GW_CT" -- journalctl -u "$OSCAR_UNIT" --since "$SINCE" --no-pager 2>/dev/null |
    grep -E "uin=$uin([^0-9]|$)" |
    grep -Eqi "login successful|authenticated successfully"
}

# The real MAC, box-side only.
station_mac() {
  local key
  key="RN_$(echo "$1" | tr 'a-z-' 'A-Z_')_MAC"
  sed -n "s/^[[:space:]]*$key=//p" "$LOCAL_ENV" 2>/dev/null | tail -1 | tr -d '"'"'"
}

check_one() {
  local s="$1" facts address tap guard mac st master unit rn fdb res ok=OK uin login=""
  if ! facts="$(station_facts "$s")"; then
    printf '%-12s no retronet block in registry/stations/%s.json  FAIL\n' "$s" "$s"
    return 1
  fi
  IFS=$'\t' read -r address tap guard <<<"$facts"
  mac="$(station_mac "$s")"

  st="$(ip -br link show "$tap" 2>/dev/null | awk '{print $2}')"
  master="$(basename "$(readlink "/sys/class/net/$tap/master" 2>/dev/null || echo none)")"
  unit="$(systemctl is-active "streamhost@$s" 2>/dev/null || true)"
  rn="$(cat "$STATIONS_DIR/$s/station.env" "$STATIONS_DIR/$s/qemu-streamhost.sh" 2>/dev/null | grep -c "$tap" || true)"
  if [ -n "$mac" ]; then
    fdb="$(bridge fdb show br "$BRIDGE" 2>/dev/null | grep -ci "$mac" || true)"
    res="$(pct exec "$GW_CT" -- grep -ci "$mac=$address" /etc/retronet/dhcp.env 2>/dev/null || true)"
  else
    fdb=0
    res=0
  fi

  if [ -n "$SINCE" ]; then
    uin="${ICQ_UIN:-$(station_uin "$s")}"
    if fresh_login "$uin"; then
      login="yes"
    else
      login="NO"
      ok=FAIL
    fi
  fi

  [ "$st" = UP ] &&
    [ "$master" = "$BRIDGE" ] &&
    [ "$unit" = active ] &&
    [ "${rn:-0}" -gt 0 ] &&
    [ -n "$mac" ] &&
    [ "${res:-0}" -gt 0 ] || ok=FAIL

  printf '%-12s tap=%-4s master=%-8s unit=%-8s env-rn=%-2s guard=%-14s fdb=%s reservation=%s%s  %s\n' \
    "$s" "${st:-none}" "${master:-none}" "${unit:-none}" "${rn:-0}" "$guard" "${fdb:-0}" "${res:-0}" \
    "${login:+ login=$login}" "$ok"
  [ "$ok" = OK ]
}

main() {
  local -a targets=()
  while :; do
    case "${1:-}" in
      --since)
        SINCE="${2:-}"
        shift 2 || usage
        ;;
      --icq)
        ICQ_UIN="${2:-}"
        shift 2 || usage
        ;;
      *) break ;;
    esac
  done
  case "${1:-}" in
    --all) mapfile -t targets < <(all_stations) ;;
    "" | -h | --help) usage ;;
    -*) usage ;;
    *) targets=("$@") ;;
  esac
  [ "${#targets[@]}" -gt 0 ] || {
    echo "rn-verify: no retronet stations to check" >&2
    exit 1
  }
  local fail=0
  for s in "${targets[@]}"; do
    check_one "$s" || fail=1
  done
  [ "$fail" = 0 ] || echo "rn-verify: see docs/lab/retronet/WEB-PLANE-PLAN.md and the station's STATION-<id>.md" >&2
  exit "$fail"
}

main "$@"
