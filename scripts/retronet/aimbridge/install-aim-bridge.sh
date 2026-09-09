#!/usr/bin/env bash
# install-aim-bridge.sh — install the AIM<->ICQ identity bridge on labhost.
# Idempotent; run as root on labhost.
#
#   ssh lab '/data/kernel-hive/scripts/retronet/aimbridge/install-aim-bridge.sh --apply'
#
# WHAT IT PROVISIONS. The bridge owns a set of gateway accounts that are NOT
# station credentials — no guest ever signs in as one:
#
#   * one ALIAS per onboarded ICQ station, named after the station
#     (win98se, nt4, os2warp, ...). Letter-leading, because that is the only
#     shape win311's AIM client will accept in a buddy list.
#   * one numeric PROXY UIN for the AIM station, with its ICQ directory
#     nickname set to the station name, because that is the only shape the ICQ
#     clients will accept as a sender.
#   * TWO always-on WATCHERS, in nobody's contact list, which observe presence
#     for the identities that are deliberately offline — one numeric and one
#     named, because presence does not cross the AIM/ICQ divide on this server
#     even though messages do (measured; see aim_bridge.py).
#
# Why the passwords are generated here and never committed: these accounts are
# an implementation detail of this service. They are written only into
# /etc/retronet/aim-bridge.json (0600) and set on the gateway in the same pass,
# so the two can never drift. Re-running rotates them, which is harmless — the
# bridge is the only thing that ever authenticates as them.
#
# The station list is DERIVED from scripts/retronet/icq/roster.json (onboarded
# rows whose greeter is the ICQ one), so adding a station to the fleet adds it
# to win311's world with no edit here. The AIM station itself is the row whose
# greeter is "aim".
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SRC/../../.." && pwd)"
DEST=/data/retronet/aimbridge
CONFIG=/etc/retronet/aim-bridge.json
UNIT=retronet-aim-bridge.service
CT=951
RN_TOOL=/opt/ras/rn-tool.py
APPLY=0

for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "install-aim-bridge.sh: unknown arg $a" >&2
      exit 2
      ;;
  esac
done

[ "$(id -u)" = 0 ] || {
  echo "install-aim-bridge.sh: must run as root on labhost" >&2
  exit 1
}

say() { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

LOCAL_ENVS=("$REPO/registry/local.env" /data/kernel-hive/registry/local.env)
from_local_env() {
  local key="$1" f val
  for f in "${LOCAL_ENVS[@]}"; do
    [ -f "$f" ] || continue
    val="$(sed -n "s/^[[:space:]]*$key=//p" "$f" | tail -1 | tr -d '"'"'"'')"
    [ -n "$val" ] && {
      printf '%s' "$val"
      return
    }
  done
}

HOST="$(from_local_env RETRONET_ICQ_HOST)"
PORT="$(from_local_env RETRONET_ICQ_PORT)"
SERVER="${RN_BRIDGE_SERVER:-${HOST:-10.99.0.2}:${PORT:-5190}}"
WATCHER_AIM="${RN_BRIDGE_WATCHER_AIM:-rnbridge}"
# Numeric, so the ICQ stations' presence is visible to it at all. Mirabilis
# reserved everything below 10000 and the server enforces it.
WATCHER_ICQ="${RN_BRIDGE_WATCHER_ICQ:-31101}"

# The roster is the single source; this prints `station alias uin` per ICQ
# station plus the AIM station's own row, and refuses rather than guess.
read -r -d '' PLAN_PY <<'PY' || true
import json, sys
sys.path.insert(0, sys.argv[1] + "/scripts/retronet/icq")
from roster_lib import load_roster, onboarded_stations, greeter_of
r = load_roster(sys.argv[1] + "/scripts/retronet/icq/roster.json")
aim = [s for s in onboarded_stations(r) if greeter_of(s) == "aim"]
if len(aim) != 1:
    sys.exit(f"expected exactly one onboarded greeter=aim station, got {len(aim)}")
a = aim[0]
print("AIM", a["station"], a["aimScreenName"], a["uin"])
for s in onboarded_stations(r, "icq"):
    print("ICQ", s["station"], s["station"], s["uin"])
PY

PLAN="$(python3 -c "$PLAN_PY" "$REPO")" || {
  echo "install-aim-bridge.sh: cannot derive the bridge plan from roster.json" >&2
  exit 1
}

AIM_LINE="$(printf '%s\n' "$PLAN" | awk '$1=="AIM"')"
AIM_STATION="$(printf '%s\n' "$AIM_LINE" | awk '{print $3}')"
PROXY_UIN="$(printf '%s\n' "$AIM_LINE" | awk '{print $4}')"

step "plan"
say "server        $SERVER"
say "AIM station   $AIM_STATION   (proxy UIN $PROXY_UIN, nickname $AIM_STATION)"
say "watchers      $WATCHER_ICQ (ICQ side) + $WATCHER_AIM (AIM side)"
printf '%s\n' "$PLAN" | awk '$1=="ICQ" {printf "  alias %-10s -> station %-10s UIN %s\n", $3, $2, $4}'

if [ "$APPLY" != 1 ]; then
  say ""
  say "PLAN ONLY — re-run with --apply to create the accounts and install the unit."
  exit 0
fi

newpass() { openssl rand -hex 4; }
ct() { pct exec "$CT" -- python3 "$RN_TOOL" "$@"; }

# `user-set` doubles as "set the password to this value" for an account that
# already exists, so create-or-rotate is one call. `user-open` clears the
# authorization requirement — without it the watcher never sees presence.
provision() {
  local name="$1" pass="$2"
  ct user-set "$name" "$pass" >/dev/null
  ct user-open "$name" >/dev/null
}

step "gateway accounts"
PROXY_PASS="$(newpass)"
WATCH_AIM_PASS="$(newpass)"
WATCH_ICQ_PASS="$(newpass)"
provision "$PROXY_UIN" "$PROXY_PASS"
provision "$WATCHER_AIM" "$WATCH_AIM_PASS"
provision "$WATCHER_ICQ" "$WATCH_ICQ_PASS"
# The ICQ side renders a UIN by its directory nickname, which is what turns
# "31100" into "win311" on eleven contact lists.
ct nick "$PROXY_UIN" "$AIM_STATION" >/dev/null
say "proxy $PROXY_UIN (nick $AIM_STATION) + watchers $WATCHER_ICQ/$WATCHER_AIM"

LINKS_JSON=""
while read -r _kind station alias uin; do
  [ -n "${uin:-}" ] || continue
  p="$(newpass)"
  provision "$alias" "$p"
  LINKS_JSON="$LINKS_JSON{\"station\":\"$station\",\"alias\":\"$alias\",\"alias_password\":\"$p\",\"uin\":\"$uin\"},"
  say "alias $alias -> $uin"
done < <(printf '%s\n' "$PLAN" | awk '$1=="ICQ"')
LINKS_JSON="[${LINKS_JSON%,}]"

step "code -> $DEST"
mkdir -p "$DEST"
install -m 0755 "$SRC/aim_bridge.py" "$DEST/aim_bridge.py"
# aim_bridge.py imports the bot's oscar.py from ../bot, so the cage needs it at
# the same relative place it has in the repo.
mkdir -p "$DEST/../bot"
install -m 0755 "$REPO/scripts/retronet/bot/oscar.py" "$DEST/../bot/oscar.py"
chmod a+rX /data/retronet "$DEST" "$DEST/../bot"

step "$CONFIG"
mkdir -p /etc/retronet
umask 077
python3 - "$CONFIG" "$SERVER" "$AIM_STATION" "$PROXY_UIN" "$PROXY_PASS" \
  "$WATCHER_AIM" "$WATCH_AIM_PASS" "$WATCHER_ICQ" "$WATCH_ICQ_PASS" "$LINKS_JSON" <<'PY'
import json, sys
path, server, aim, puin, ppass, waim, waimpass, wicq, wicqpass, links = sys.argv[1:11]
json.dump({
    "server": server,
    "aim_station": aim,
    "proxy": {"uin": puin, "password": ppass},
    "watcher_aim": {"name": waim, "password": waimpass},
    "watcher_icq": {"uin": wicq, "password": wicqpass},
    "links": json.loads(links),
}, open(path, "w"), indent=2)
PY
chmod 0600 "$CONFIG"
say "wrote $CONFIG (0600) — $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["links"]))' "$CONFIG") link(s)"

step "unit"
install -m 0644 "$SRC/$UNIT" "/etc/systemd/system/$UNIT"
DROPIN="/etc/systemd/system/$UNIT.d/10-server.conf"
if [ "${SERVER%%:*}" != "10.99.0.2" ]; then
  mkdir -p "$(dirname "$DROPIN")"
  printf '[Service]\nIPAddressAllow=%s\n' "${SERVER%%:*}" >"$DROPIN"
else
  rm -f "$DROPIN"
fi
systemctl daemon-reload
systemctl enable "$UNIT"
systemctl restart "$UNIT"
systemctl --no-pager --lines=12 status "$UNIT" || true
