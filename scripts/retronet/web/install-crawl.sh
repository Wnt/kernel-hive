#!/usr/bin/env bash
# install-crawl.sh — deploy the era-press corpus crawl as a systemd unit INSIDE
# the dev container CT 950 (the only box with internet). Idempotent.
#
# It deploys a COPY of era-press.py + its modules (era_press_core.py, era_crawl.py)
# + era-sites.json into the shared volume dir so
# the running crawl never depends on a git worktree that may be GC'd mid-run, then
# installs, enables and starts retronet-crawl.service. The crawl is resumable, so
# re-running (or a reboot) continues from the on-disk corpus + state.json.
#
# RUNS ON CT 950 (needs sudo + internet + the corpus volume mounted). Either:
#   scripts/retronet/web/install-crawl.sh
#   ssh lab 'pct exec 950 -- bash /data/kernel-hive/scripts/retronet/web/install-crawl.sh'
#
# As-built: docs/lab/retronet/ERA-PRESS.md.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${RN_CRAWL_DIR:-/data/vms/retronet-crawl}"  # deployed runtime + state + log (stable)
CORPUS="${RN_CORPUS_VOL:-/data/vms/retronet-corpus}" # the shared corpus volume
UNIT="retronet-crawl.service"

if [ ! -d "$CORPUS" ]; then
  echo "install-crawl: corpus volume $CORPUS is missing — run install-corpus-volume.sh on labhost first" >&2
  exit 1
fi

echo "deploying crawl runtime -> $RUN_DIR"
# /data/vms is root-owned; make the runtime dir and hand it to the crawl user so
# the service (User below) can write state.json + progress.log there.
sudo mkdir -p "$RUN_DIR"
sudo chown "$(id -un):$(id -gn)" "$RUN_DIR"
cp "$SRC/era-press.py" "$SRC/era_press_core.py" "$SRC/era_crawl.py" "$SRC/era-sites.json" "$RUN_DIR/"

# --- fetch-layer dependency: httpx[http2] in a dedicated venv ------------------
# era_press_core.http_get speaks HTTP/2 over a SMALL reused connection pool via httpx -- the cure for the
# NAT/conntrack exhaustion the old new-connection-per-request transport caused. Ubuntu 24.04 is PEP-668
# externally-managed, so httpx lives in a venv beside the deployed code (never system pip); the unit's
# ExecStart runs venv/bin/python. Pinned + idempotent (venv reused if present, pip is a no-op when met).
PIN='httpx[http2]==0.28.1'
VENV="$RUN_DIR/venv"
if ! python3 -c 'import ensurepip' 2>/dev/null; then
  echo "installing python3-venv (needed to build the crawl venv)"
  sudo apt-get update -qq && sudo apt-get install -y -qq python3-venv
fi
if [ ! -x "$VENV/bin/python" ]; then
  echo "creating crawl venv -> $VENV"
  python3 -m venv "$VENV"
fi
echo "ensuring $PIN in the crawl venv (pinned, idempotent)"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet "$PIN"
"$VENV/bin/python" -c 'import httpx, h2; print("  venv httpx", httpx.__version__, "/ h2", h2.__version__)'

echo "installing $UNIT"
sudo cp "$SRC/$UNIT" "/etc/systemd/system/$UNIT"
sudo systemctl daemon-reload
sudo systemctl enable --now "$UNIT"

echo "--- status ---"
systemctl --no-pager --lines=0 status "$UNIT" || true
echo "watch:   tail -f $RUN_DIR/progress.log"
echo "or:      journalctl -u $UNIT -f"
