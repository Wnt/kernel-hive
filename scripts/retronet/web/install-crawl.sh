#!/usr/bin/env bash
# install-crawl.sh — deploy the era-press corpus crawl as a systemd unit INSIDE
# the dev container CT 950 (the only box with internet). Idempotent.
#
# It deploys a COPY of era-press.py + its modules (era_fetch.py, era_index.py,
# era_press_core.py, era_crawl.py, era_requests.py, era_state.py) + the site lists
# (era-sites.json, era-vips.json) into the shared volume dir so
# the running crawl never depends on a git worktree that may be GC'd mid-run, then
# installs, enables and starts retronet-crawl.service. The crawl is resumable, so
# re-running (or a reboot) continues from the on-disk corpus + state.json.
#
# RUNS ON CT 950 (needs sudo + internet + the corpus volume mounted). Either:
#   scripts/retronet/web/install-crawl.sh
#   ssh lab 'pct exec 950 -- bash /data/kernel-hive/scripts/retronet/web/install-crawl.sh'
#
# Deploys code and units; does NOT restart a running crawl (that costs a full corpus
# re-sweep). To apply an era-sites.json / era-vips.json edit, pass --restart.
#
# As-built: docs/lab/retronet/ERA-PRESS.md.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${RN_CRAWL_DIR:-/data/vms/retronet-crawl}"  # deployed runtime + state + log (stable)
CORPUS="${RN_CORPUS_VOL:-/data/vms/retronet-corpus}" # the shared corpus volume
UNIT="retronet-crawl.service"
REQ_UNIT="retronet-requests.service"
SPOOL="${RN_REQ_VOL:-/data/vms/retronet-requests}" # miss-journal spool, shared with the gateway CT

if [ ! -d "$CORPUS" ]; then
  echo "install-crawl: corpus volume $CORPUS is missing — run install-corpus-volume.sh on labhost first" >&2
  exit 1
fi
if [ ! -d "$SPOOL" ]; then
  echo "install-crawl: miss-journal spool $SPOOL is missing — run install-requests-volume.sh on labhost first" >&2
  exit 1
fi

echo "deploying crawl runtime -> $RUN_DIR"
# /data/vms is root-owned; make the runtime dir and hand it to the crawl user so
# the services (User= in both units) can create state.json, requests.json and
# their logs there.
#
# Name that user EXPLICITLY rather than taking `id -un`. This script is run both
# as wnt and, as the docs' own one-liner does, via `pct exec 950 --` where it is
# root -- and then `id -un` handed the runtime dir to root, leaving User=wnt able
# to append to files that already existed but unable to create a new one. That is
# invisible until a unit first writes a NEW file, which is exactly how
# retronet-requests.service crash-looped on its own log the first time it ran.
RUN_USER="${RN_CRAWL_USER:-wnt}"
sudo mkdir -p "$RUN_DIR"
sudo chown -R "$RUN_USER:$RUN_USER" "$RUN_DIR"
cp "$SRC/era-press.py" "$SRC/era_fetch.py" "$SRC/era_index.py" "$SRC/era_press_core.py" "$SRC/era_crawl.py" \
  "$SRC/era_requests.py" "$SRC/era_sweep.py" "$SRC/era_state.py" \
  "$SRC/era-sites.json" "$SRC/era-vips.json" "$RUN_DIR/"

# --- fetch-layer dependency: httpx[http2] in a dedicated venv ------------------
# era_fetch.http_get speaks HTTP/1.1 over a bounded reused connection pool via httpx -- the cure for the
# NAT/conntrack exhaustion the old new-connection-per-request transport caused. Ubuntu 24.04 is PEP-668
# externally-managed, so httpx lives in a venv beside the deployed code (never system pip); the unit's
# ExecStart runs venv/bin/python. Pinned + idempotent (venv reused if present, pip is a no-op when met).
# httpx for the transport (HTTP/1.1 -- measured 4x faster here than h2, see ERA-PRESS.md); brotli+zstandard so httpx can decode the br/zstd encodings the
# browser-identical Accept-Encoding advertises (whatever archive.org sends is stored as raw decoded bytes).
PINS=('httpx==0.28.1' 'brotli==1.2.0' 'zstandard==0.25.0')
VENV="$RUN_DIR/venv"
if ! python3 -c 'import ensurepip' 2>/dev/null; then
  echo "installing python3-venv (needed to build the crawl venv)"
  sudo apt-get update -qq && sudo apt-get install -y -qq python3-venv
fi
if [ ! -x "$VENV/bin/python" ]; then
  echo "creating crawl venv -> $VENV"
  python3 -m venv "$VENV"
fi
echo "ensuring pinned deps in the crawl venv (idempotent): ${PINS[*]}"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet "${PINS[@]}"
"$VENV/bin/python" -c 'import httpx, brotli, zstandard; print("  venv httpx", httpx.__version__, "/ brotli+zstandard OK")'

# Smoke-import the deployed tree with the venv python. era_crawl pulls in every other module, so a module
# added to the source dir but forgotten in the cp list above fails HERE -- loudly, before the unit is
# restarted -- instead of becoming a ModuleNotFoundError restart-loop in journalctl (it did, 2026-08-22).
echo "smoke: importing the deployed crawl modules"
(cd "$RUN_DIR" && "$VENV/bin/python" -c 'import era_crawl' && echo "  deployed modules import OK")

echo "installing $UNIT + $REQ_UNIT"
sudo cp "$SRC/$UNIT" "/etc/systemd/system/$UNIT"
sudo cp "$SRC/$REQ_UNIT" "/etc/systemd/system/$REQ_UNIT"
sudo systemctl daemon-reload
sudo systemctl enable "$UNIT" "$REQ_UNIT"
# The crawl is NOT restarted as a side effect of running this script.
#
# It used to be, on the reasoning that this is the one command that applies an era-sites.json or
# era-vips.json edit and `--now` is a no-op on a running daemon. The reasoning was right about edits and
# wrong about everything else: deploying code, adding a unit, or repairing an install also restarted it,
# and a restart is not free. A restart re-plans every site and re-runs the resource sweep across the
# whole corpus -- measured 2026-08-24, an install with an UNCHANGED site list cost ~970 requests to
# archive.org in eleven minutes and did not grow the corpus by a single byte. (The absent-resource
# ledger now blunts that, but the right answer is still not to restart something nobody asked to
# restart.) It also churns the search reindexer, which rebuilds whenever the corpus fingerprint moves.
#
# So: start it if it is not running, and restart it only when asked. Applying a site-list edit is now
# an explicit `--restart`, which is the case that genuinely needs one.
if [ "${1:-}" = "--restart" ]; then
  echo "  --restart: applying the site list to a running crawl"
  sudo systemctl restart "$UNIT"
elif systemctl is-active --quiet "$UNIT"; then
  echo "  $UNIT already running — left alone (use --restart to apply a site-list edit)"
else
  echo "  $UNIT not running — leaving it stopped (start it with: systemctl start $UNIT)"
fi
# The demand channel IS restarted every time: it has no natural completion, its startup is cheap, and
# it makes no request to archive.org just for starting -- so picking up new code costs nothing here.
sudo systemctl restart "$REQ_UNIT"

echo "--- status ---"
systemctl --no-pager --lines=0 status "$UNIT" || true
systemctl --no-pager --lines=0 status "$REQ_UNIT" || true
echo "watch:   tail -f $RUN_DIR/progress.log"
echo "or:      tail -f $RUN_DIR/requests.log"
echo "or:      journalctl -u $UNIT -f"
