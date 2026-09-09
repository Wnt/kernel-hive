#!/usr/bin/env python3
"""Ship the daemon's spooled spans AND log records into their stores.

RUN THIS ON THE BOX, via `scripts/dev/labrun`, not from CT950. The spool files
under `/data/vms/streamhost/stations/<station>/{traces,logs}/` are written by the
daemon as root; on the box this tool also runs as root and can delete what it
ships. From CT950 it runs as `wnt` and the POST still succeeds — the store does
not care who shipped it — but the unlink cannot, so every batch gets re-sent on
every future run until someone deletes it as root anyway. `--apply --keep` is
the only sanctioned way to run this off the box, and even then the spool grows
until something on the box catches up.

    ssh lab 'scripts/dev/labrun scripts/observability/trace-ship.py'
                                                    PLAN ONLY: what is waiting
    scripts/dev/labrun scripts/observability/trace-ship.py --apply
                                                    POST each batch, delete on 200
    scripts/observability/trace-ship.py --apply --keep    ship, but keep the files

THE HOP THAT WAS MISSING. `streamhost` deliberately owns no HTTP client: a
station that cannot reach the collector must keep streaming, so it writes each
batch to `<station>/traces/` (and its log records to `<station>/logs/`)
with tmp+rename and moves on
(`streamhost/src/trace/spool.rs`). That makes the FILE the request body — but
until something carries it, every daemon span is a file on a disk that nothing
reads, and `/admin/observability` shows a browser and a serving plane with a
hole where the daemon should be. This is that carrier, and it is the whole of
it: read a file, POST it verbatim to `/traces` or `/logs`, delete it when the
store says it took it. Both lanes ride ONE walk, one timer and one
single-flight guarantee — see `LANES` for why a second shipper would be worse.

IT IS RUN ON A TIMER SINCE 2026-09-01, and the argument this docstring used to
make for hand-running it was answered by what hand-running actually cost. The
reasoning was sound about the SPOOL — it is bounded (`SH_TRACE_SPOOL_MAX`,
oldest dropped), so nothing fills up while nobody ships — and wrong about the
STORE: an unshipped batch is a daemon span missing from `/admin/observability`
and from everything downstream of it, so "nothing fills up" was never the same
claim as "nothing is lost". `kh-trace-ship.{service,timer}` beside this file
runs `--apply` every two minutes; systemd owns the single-flight guarantee (a
oneshot unit cannot overlap itself, and a tick during a run is dropped rather
than queued). It keeps no watermark to lose across a restart — the spool
directory IS the state, and a batch is deleted only after the store says it
took it. Installing the unit does not start it; enabling it is an operator
decision, spelled out in docs/lab/INSTANA-VIEW-INVENTORY.md §2.

ONLY COMPLETE FILES ARE EVER READ. The daemon publishes with tmp+rename, so a
name matching `*.json` in the spool is finished by construction and a partial
batch cannot be picked up mid-write. A file that fails to ship is LEFT WHERE IT
IS: the next run retries it, and the daemon's own cap is what stops it growing
without end. Deleting on anything but a 200 would lose the records this exists
to carry. RETRY IS SAFE IN BOTH LANES, by two different mechanisms: the span
store is idempotent per span (`traces.py` inserts `ON CONFLICT(trace_id,
span_id) DO NOTHING`), and the log store — where two identical lines a
millisecond apart are two real events, not a duplicate — is idempotent per
BATCH, on the spool filename this tool stamps in (`stamp_batch_id`). Without
both, "leave it and retry" would be a duplication bug.

TLS: the collector is the box's own listener on loopback with the self-signed
cert `serve-https-spa.sh` generates, so verification is off for 127.0.0.1 and
nothing else. That is not a relaxed check on a public endpoint; it is the same
process, on the same machine, one hop through its own socket.
"""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STATIONS = Path("/data/vms/streamhost/stations")
# 127.0.0.1 is right when this runs ON the box. From CT950 the serving plane is
# a hop away on the LAN, and its address is deployment-local: it lives in
# gitignored registry/local.env, never in a committed default.
COLLECTOR_PORT = 8443
BOLD, RED, GRN, YLW, DIM, OFF = "\033[1m", "\033[31m", "\033[32m", "\033[33m", "\033[2m", "\033[0m"


#: The two lanes this carries, as (spool subdirectory, collector route). The
#: daemon writes both with the same tmp+rename dance into sibling directories,
#: and both files ARE their request body, so one walk and one POST loop serve
#: both. A second shipper for logs would be a second timer, a second
#: single-flight guarantee and a second place for the unlink rule to be got
#: wrong — see `streamhost/src/trace/logs.rs` on why the carrier is shared.
LANES = (("traces", "/traces", "spans"), ("logs", "/logs", "logs"))


def collector_base() -> str:
    """The box's own listener, addressed the way this host can reach it."""
    host = "127.0.0.1"
    try:
        for line in (ROOT / "registry" / "local.env").read_text().splitlines():
            if line.strip().startswith("SH_HOST_IP="):
                host = line.split("=", 1)[1].strip().strip("\"'") or host
    except OSError:
        pass
    return f"https://{host}:{COLLECTOR_PORT}"


def batches(root: Path, lane: str = "traces"):
    """Every finished spool file in one lane, oldest first, as (station, path).

    Oldest first because the store keeps the first summary it sees for a trace,
    and shipping a session's spans out of order would summarise it backwards.
    Log records have no such ordering constraint, but they get the same walk:
    one rule is easier to keep true than two.
    """
    found = []
    for spool in sorted(root.glob(f"*/{lane}")):
        for path in sorted(spool.glob("*.json"), key=lambda p: p.name):
            found.append((spool.parent.name, path))
    return found


def record_count(path: Path, key: str) -> int:
    """Records in one batch, or 0 for a file the store will refuse anyway."""
    try:
        doc = json.loads(path.read_text())
        return len(doc.get(key) or [])
    except (OSError, ValueError):
        return 0


def stamp_batch_id(body: bytes, name: str) -> bytes:
    """Name the batch after its spool file, for the LOG lane's idempotency.

    The span store dedupes on `(trace_id, span_id)` and needs nothing here. A
    log record has no natural key — two identical lines a millisecond apart are
    two real events — so `logs.py` dedupes on a batch id instead, and the spool
    filename is unique by construction (millisecond stamp, pid, sequence). It
    is stamped HERE rather than in the daemon because it identifies the FILE,
    and the daemon does not know its own file's name until `write_batch`
    renames it. A body we cannot parse is passed through untouched: the store
    is what refuses it, and rewriting it first would only change the error.
    """
    try:
        doc = json.loads(body)
    except ValueError:
        return body
    if not isinstance(doc, dict):
        return body
    doc.setdefault("batchId", name)
    return json.dumps(doc, separators=(",", ":")).encode()


def post(url: str, body: bytes, timeout: int = 30) -> tuple[bool, str]:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            answer = json.loads(r.read().decode("utf-8", "replace") or "{}")
            return bool(answer.get("ok")), json.dumps(answer)[:200]
    except (urllib.error.URLError, ValueError, OSError) as exc:
        return False, str(exc)[:200]


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--apply", action="store_true", help="actually POST (default: plan only)")
    p.add_argument("--keep", action="store_true", help="do not delete a batch the store accepted")
    p.add_argument("--collector", default=None, help="override the collector base URL")
    p.add_argument("--stations", default=str(STATIONS))
    p.add_argument("--lane", choices=[n for n, _, _ in LANES], help="ship only one lane (default: both)")
    args = p.parse_args(argv)
    args.collector = (args.collector or collector_base()).rstrip("/")
    lanes = [x for x in LANES if not args.lane or x[0] == args.lane]

    root = Path(args.stations)
    if not root.is_dir():
        print(f"    [{RED}FAIL{OFF}] no station tree at {root}")
        return 1
    waiting = [(lane, route, key, station, path) for lane, route, key in lanes for station, path in batches(root, lane)]
    if not waiting:
        print(f"\n{BOLD}==> nothing spooled{OFF}")
        print(f"    {DIM}no daemon has written a batch since the last ship{OFF}")
        return 0

    per_station: dict[tuple[str, str], int] = {}
    for lane, _route, key, station, path in waiting:
        per_station[(station, lane)] = per_station.get((station, lane), 0) + record_count(path, key)
    total = sum(per_station.values())
    stations = len({s for s, _ in per_station})
    print(f"\n{BOLD}==> {len(waiting)} batch(es), {total} record(s), {stations} station(s){OFF}")
    for station, lane in sorted(per_station):
        print(f"    {station:<14} {lane:<7} {per_station[(station, lane)]}")

    if not args.apply:
        print(f"\n{BOLD}==> PLAN ONLY — nothing was sent{OFF}")
        print(f"    {DIM}re-run with --apply to POST these to {args.collector}{OFF}")
        return 0

    print(f"\n{BOLD}==> shipping to {args.collector}{OFF}")
    sent = failed = stuck = 0
    for lane, route, _key, station, path in waiting:
        body = path.read_bytes()
        if lane == "logs":
            body = stamp_batch_id(body, path.name)
        okd, detail = post(args.collector + route, body)
        if not okd:
            print(f"    [{RED}FAIL{OFF}] {station} {path.name}: {detail}")
            failed += 1
            continue
        sent += 1
        if args.keep:
            continue
        # The store already has these spans; a failure past this point is ours,
        # not the store's, and must never look like a shipping failure. The
        # usual cause is running off the box (see the module docstring) — root
        # wrote the spool file, this process is not root, unlink is refused.
        # The file is left in place, which is safe (the next run just re-ships
        # a batch the store will happily see again) but is not silent: leaving
        # it unreported would mean the spool grows forever and nobody notices.
        try:
            path.unlink()
        except OSError:
            stuck += 1
    print(
        f"    [{GRN}OK{OFF}] shipped {sent} batch(es)"
        + (f"; {YLW}{failed} left for the next run{OFF}" if failed else "")
    )
    if stuck:
        print(
            f"    [{YLW}WARN{OFF}] {stuck} shipped batch(es) could not be deleted "
            f"(stored already — will be re-sent unless this runs on the box as root)"
        )
    return 1 if (failed or stuck) else 0


if __name__ == "__main__":
    sys.exit(main())
