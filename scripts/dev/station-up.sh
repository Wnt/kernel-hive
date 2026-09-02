#!/usr/bin/env bash
# station-up.sh — bring a brand-new, ALREADY-DEPLOYED station online on labhost
# in ONE command.
#
# WHY. bootos, 2026-09-02: after `box-deploy.sh --apply` had landed the tree, the
# coordinator still spent ~8 minutes and two retries doing by hand what this
# script does: a single-station emit (stations-manifest.sh has no --only, so a
# temp script is cut from its header + the station's emit block), the binary
# symlink the fleet deploy does not create for a station it has never seen,
# the unit start + LISTENING check, the FIVE runtime manifests, `labctl gen`,
# a shot, and the signal / manifest / restore checks. Each step is trivial; the
# sequence is not, and forgetting one produces a station that "streams fine"
# but is missing from /fleet or has a dead reset button (playbook §7.2).
#
# usage: scripts/dev/station-up.sh [--no-start] [--no-restore] <stationDir>
#   --no-start    skip `systemctl start streamhost@<id>` + the LISTENING check
#   --no-restore  skip the final `POST /restore/<id>` (it DOES reset the guest)
#
# Idempotent: safe on a live station — re-emit is byte-identical, `systemctl
# start` on an active unit is a no-op, manifests are re-rendered from the same
# registry. Runs from CT950; box checkout /data/kernel-hive must already be at
# the wanted main commit (box-deploy.sh --apply), else this fails loudly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LABRUN="$SCRIPT_DIR/labrun"
LAB="${LAB:-lab}"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/kh-session.sh" 2>/dev/null || true

no_start=0
no_restore=0
id=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-start) no_start=1 ;;
    --no-restore) no_restore=1 ;;
    -h | --help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    -*)
      echo "station-up: unknown flag $1" >&2
      exit 2
      ;;
    *) id="$1" ;;
  esac
  shift
done
[ -n "$id" ] || {
  echo "usage: station-up.sh [--no-start] [--no-restore] <stationDir>" >&2
  exit 2
}
case "$id" in
  *[!a-z0-9_-]*)
    echo "station-up: bad station id '$id'" >&2
    exit 2
    ;;
esac

step() { printf '\n== %s\n' "$*"; }
fail() {
  echo "station-up: FAIL: $*" >&2
  exit 1
}

# ---- 0. box checkout must be a deployed main ---------------------------------
step "0 deployed rev on the box"
rev="$(ssh -n "$LAB" 'cat /data/vms/streamhost/.deployed-rev 2>/dev/null' || true)"
while IFS= read -r l; do echo "   $l"; done <<<"$rev"
echo "$rev" | grep -Eq '^branch=main$|main@' ||
  fail ".deployed-rev is not a deployed main — run scripts/dev/box-deploy.sh --apply first"
ssh -n "$LAB" "grep -q '^emit $id ' /data/kernel-hive/streamhost/stations-manifest.sh" ||
  fail "no 'emit $id' block in /data/kernel-hive/streamhost/stations-manifest.sh (not deployed?)"

# ---- 1. single-station emit + 2. binary symlink (+3. start) — one labrun -----
step "1-3 emit, binary, start (on labhost)"
"$LABRUN" "$id" "$no_start" "${STATION_UP_LISTEN_TIMEOUT:-60}" <<'EOF_REMOTE'
id="$1"
no_start="$2"
listen_timeout="$3"
cd /data/kernel-hive/streamhost
tmp="./.emit-$id-once.sh"
trap 'rm -f "$tmp"' EXIT
# header = everything before the first `emit ` line; then this station's block.
sed -n '1,/^emit /{/^emit /!p}' stations-manifest.sh >"$tmp"
awk "/^emit $id /,/^\$/" stations-manifest.sh >>"$tmp"
grep -q "^emit $id " "$tmp" || {
  echo "emit block for $id not found" >&2
  exit 1
}
echo "-- emit $id --pin-machine"
bash "$tmp" --pin-machine
rm -f "$tmp"

sd="/usr/local/lib/streamhost/stations/$id"
if [ ! -e "$sd/current" ]; then
  fleet_bin="$(for l in /usr/local/lib/streamhost/stations/*/current; do
    [ -L "$l" ] && readlink -f "$l"
  done | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
  [ -n "$fleet_bin" ] && [ -x "$fleet_bin" ] || {
    echo "no fleet binary found among stations/*/current" >&2
    exit 1
  }
  mkdir -p "$sd"
  ln -s "$fleet_bin" "$sd/current"
  echo "-- binary: created $sd/current -> $fleet_bin"
else
  echo "-- binary: $sd/current -> $(readlink -f "$sd/current") (kept)"
fi

if [ "$no_start" = 1 ]; then
  echo "-- --no-start: not starting streamhost@$id"
  exit 0
fi
echo "-- systemctl start streamhost@$id"
systemctl start "streamhost@$id"
labctl wait-for --unit "streamhost@$id"
echo "-- journal tail"
journalctl -u "streamhost@$id" -n 12 --no-pager -o cat | sed 's/^/   /'
# whole current invocation: on a long-lived station the LISTENING line is old.
inv="$(systemctl show -p InvocationID --value "streamhost@$id")"
lst=""
waited=0
while [ "$waited" -lt "$listen_timeout" ]; do
  lst="$(journalctl "_SYSTEMD_INVOCATION_ID=$inv" --no-pager -o cat | grep 'LISTENING udp/' | tail -1 || true)"
  [ -n "$lst" ] && break
  sleep 1
  waited=$((waited + 1))
done
[ -n "$lst" ] || {
  echo "no 'LISTENING udp/' line in the journal of streamhost@$id after ${listen_timeout}s" >&2
  exit 1
}
echo "-- waited ${waited}s"
echo "   $lst"
EOF_REMOTE

# ---- 4. the five runtime documents (from CT950, opens its own ssh lab) -------
step "4 publish runtime manifests"
"$REPO_ROOT/scripts/serve-https-spa.sh" manifests

# ---- 5. gen, ls, shot, checks ---------------------------------------------
step "5 labctl gen / ls / shot / checks"
if [ -n "${KH_SESSION:-}" ]; then
  shot="/data/vms/sandbox/$KH_SESSION/$id-up.png"
else
  shot="/tmp/$id-up.png"
fi
"$LABRUN" "$id" "$shot" "$no_start" "$no_restore" <<'EOF_REMOTE'
id="$1"
shot="$2"
no_start="$3"
no_restore="$4"
rc=0
labctl gen >/dev/null
echo "-- labctl ls"
labctl ls | grep -F -- "$id" | sed 's/^/   /' || {
  echo "   $id not in labctl ls"
  rc=1
}
if [ "$no_start" = 0 ]; then
  mkdir -p "$(dirname "$shot")"
  labctl shot "$id" "$shot" && echo "-- shot: $shot" || {
    echo "   labctl shot failed"
    rc=1
  }
fi
echo "-- signal"
sig="$(curl -ksS "https://127.0.0.1:8443/signal/$id.json")" || sig=""
for key in udpPort certHashB64; do
  if echo "$sig" | grep -q "\"$key\""; then
    echo "   $key: present"
  else
    echo "   $key: MISSING"
    rc=1
  fi
done
echo "-- manifests"
S=/data/vms/streamhost/serve
for f in "$S/webroot/gallery-manifest.json" "$S/webroot/poster-docs.json" \
  "$S/webroot/fleet-table.json" "$S/golden-manifest.json" "$S/tiles.json"; do
  if grep -q "\"$id\"" "$f" 2>/dev/null; then
    echo "   ${f#"$S"/}: has $id"
  else
    echo "   ${f#"$S"/}: MISSING $id"
    rc=1
  fi
done
if [ "$no_restore" = 0 ] && [ "$no_start" = 0 ]; then
  code="$(curl -ksS -o /dev/null -w '%{http_code}' -X POST "https://127.0.0.1:8443/restore/$id")"
  echo "-- POST /restore/$id -> $code"
  [ "$code" = 200 ] || rc=1
else
  echo "-- restore check skipped"
fi
exit "$rc"
EOF_REMOTE

step "SUMMARY $id"
echo "   emit     : re-emitted with --pin-machine"
echo "   binary   : stations/$id/current present"
if [ "$no_start" = 1 ]; then
  echo "   unit     : not started (--no-start)"
else
  echo "   unit     : streamhost@$id active, LISTENING udp/"
  echo "   shot     : $shot"
fi
echo "   manifests: 5 runtime docs published and contain \"$id\""
echo "   next     : open /os/$id in the SPA and look at the framebuffer (rule 9)"
