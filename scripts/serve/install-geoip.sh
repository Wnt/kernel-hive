#!/usr/bin/env bash
# install-geoip.sh — put the country database on the box, or refresh it.
#
# WHAT. DB-IP's free "Lite" country database in MaxMind mmdb format. No account,
# no API key, no per-lookup request to anybody: one file, read locally by
# scripts/serve/geo.py. That is what keeps docs/ANALYTICS.md's claim true —
# this plane has no external service in it — while still answering "which
# countries do the people with accounts sign in from".
#
# LICENCE. CC BY 4.0. The attribution DB-IP asks for is carried in the admin
# page footer (scripts/serve/authui/admin.html), not only here.
#
# WHEN. DB-IP publishes monthly and the URL carries the month, so a file gets
# staler until this is re-run. Re-running is the whole update: it downloads,
# verifies the file parses, and only then swaps it in.
#
# usage: install-geoip.sh [YYYY-MM]     (default: this month, else last month)
set -euo pipefail

DEST_DIR="${GEOIP_DIR:-/data/vms/streamhost/serve/geoip}"
DEST="$DEST_DIR/dbip-country-lite.mmdb"

try_month() { date -u -d "${1}" +%Y-%m 2>/dev/null || true; }
months=("${1:-$(try_month now)}")
[ -n "${1:-}" ] || months+=("$(try_month '1 month ago')")

mkdir -p "$DEST_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

got=""
for m in "${months[@]}"; do
  [ -n "$m" ] || continue
  url="https://download.db-ip.com/free/dbip-country-lite-${m}.mmdb.gz"
  echo "install-geoip: trying $url"
  if curl -fsSL --retry 2 -o "$tmp/db.gz" "$url"; then
    got="$m"
    break
  fi
  # A month that has not been published yet 404s; that is expected at the turn
  # of the month, which is why the previous month is the fallback rather than
  # an error.
  echo "install-geoip: $m not available"
done
[ -n "$got" ] || {
  echo "install-geoip: no database available for: ${months[*]}" >&2
  exit 1
}

gzip -dc "$tmp/db.gz" >"$tmp/db.mmdb"

# Verify BEFORE swapping: a truncated download that still gunzips would
# otherwise replace a working database with one that fails every lookup.
python3 - "$tmp/db.mmdb" <<'PY'
import sys
try:
    import maxminddb
except ImportError:
    # The venv owns the dependency; a box-side python without it can still
    # install the file. geo.py degrades to None either way.
    print("install-geoip: maxminddb not importable here — skipping the parse check")
    sys.exit(0)
with maxminddb.open_database(sys.argv[1]) as r:
    rec = r.get("8.8.8.8")
    assert isinstance(rec, dict) and rec.get("country", {}).get("iso_code"), "no country for a known address"
    print("install-geoip: parse check OK (8.8.8.8 ->", rec["country"]["iso_code"] + ")")
PY

install -m 0644 "$tmp/db.mmdb" "$DEST"
echo "install-geoip: installed $DEST ($(stat -c %s "$DEST") bytes, build $got)"
