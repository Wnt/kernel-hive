#!/usr/bin/env python3
"""Verify that every tile's signalling doc carries a ticket that tile will accept.

RUN ON THE BOX:  python3 /data/vms/streamhost/serve/check-stream-tickets.py

The gateway signs a stream ticket over the tile's identity, and streamhost
verifies it against its own `SH_STATION`. Those are still two different SOURCES for
one name. They disagreed by design until 2026-08-10, when the last two exhibits
whose id differed from their daemon's — `solaris`/`solariscde` and
`aros`/`amigaos` — were renamed; on 2026-08-05 the gateway had signed with the
SPA's name and both tiles refused every session with `bad signature`. They
streamed for a moment on an already-open session, then went dead the next time a
client reconnected, which reads to a visitor as "it froze after I clicked".

Nothing detected it: the tile was up, the daemon was healthy, the signalling doc
looked perfect, and the failure lived in the relationship between two documents.
The names agree by construction now (stations-registry.py refuses an id that
differs from its stationDir), but a station.env is edited ON THE BOX and never passes
through that gate, so the relationship is still worth proving. This checks it —
it recomputes each ticket's HMAC exactly as the daemon does and reports the
tiles that would refuse a connection.

Walk-in pool clones (`walkin-<os>-<n>`, docs/lab/walkin/CONTRACT-LEDGER.md §5.1)
are ephemeral daemon identities, not registry stations: they appear in
`tiles.json` so `/signal/<clone>.json` can resolve, and they are STOPPED most of
the time. A stopped slot is the pool's normal resting state, so it is reported
as `idle` and never counted as a failure — otherwise enabling walk-in would make
this check red on a healthy fleet. A clone that IS running is held to exactly
the same ticket check as a station.

Exit 0 = every running tile would accept its own ticket.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import re
import ssl
import sys
import urllib.request
from pathlib import Path

SERVE = Path("/data/vms/streamhost/serve")
GATEWAY = "https://127.0.0.1:8443"

# Clone identity, frozen by docs/lab/walkin/CONTRACT-LEDGER.md §5.1. The `<os>`
# half is a station id, so it is matched loosely on purpose: this file must not
# become a second place where the pool's OS list is declared.
WALKIN_ID = re.compile(r"^walkin-(?P<os>[a-z0-9]+)-(?P<slot>\d+)$")


def walkin_os(name: str) -> str | None:
    """The pool an identity belongs to, or None for a registry station."""
    m = WALKIN_ID.match(name)
    return m.group("os") if m else None


def gateway_signal(tile: str) -> dict:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(f"{GATEWAY}/signal/{tile}.json", timeout=10, context=ctx) as r:
        return json.loads(r.read())


def daemon_identity(hash_file: str) -> str | None:
    """The tile id the DAEMON published — the one it verifies against."""
    try:
        return json.loads(Path(hash_file).with_name("signaling.json").read_text()).get("tile")
    except OSError:
        return None


def verify(key: bytes, ticket_path: str, tile: str) -> tuple[bool, str]:
    """Re-run streamhost's check (see streamhost/src/session_ticket.rs)."""
    if not ticket_path.startswith("/wt/"):
        return False, "no ticket in path"
    parts = ticket_path[len("/wt/") :].split(".")
    if len(parts) != 3:
        return False, "malformed ticket"
    exp, nonce, sig = parts
    msg = f"v1|{tile}|{exp}|{nonce}".encode()
    want = base64.urlsafe_b64encode(hmac.new(key, msg, hashlib.sha256).digest()).rstrip(b"=").decode()
    return (True, "ok") if hmac.compare_digest(want, sig) else (False, "bad signature")


def check_one(key: bytes, name: str, identity: str) -> tuple[bool, str]:
    """Verify the ticket the gateway mints for `name` against `identity`."""
    try:
        doc = gateway_signal(name)
    except Exception as exc:  # noqa: BLE001 — any failure here is a failure to report
        return False, f"gateway said {type(exc).__name__}"
    ticket = doc.get("path")
    if not ticket:
        return False, "signalling carries no ticket"
    return verify(key, ticket, identity)


def report_pool(pool: dict[str, dict[str, list[str]]]) -> None:
    """Pool health, per OS. Idle slots are normal, not a complaint."""
    print()
    print("--- walk-in pool ---")
    if not pool:
        print("  no walk-in clones in tiles.json (pool not provisioned, or access closed)")
        return
    for os_name, slots in sorted(pool.items()):
        live, idle, bad = slots["live"], slots["idle"], slots["bad"]
        total = len(live) + len(idle) + len(bad)
        line = f"  {os_name:<12} {total} slot(s): {len(live)} live, {len(idle)} idle"
        if bad:
            line += f", {len(bad)} REFUSING"
        print(line)
        if bad:
            print(f"    refusing: {', '.join(sorted(bad))}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument(
        "--relay-range",
        metavar="LOW-HIGH",
        help=(
            "also flag any tile whose udpPort falls outside the edge VPS's DNAT range "
            "(registry-v1.json ports.publicRelayLow/High). Off by default so this file "
            "does not become another place the range is declared."
        ),
    )
    args = ap.parse_args()
    lo = hi = None
    if args.relay_range:
        lo, hi = (int(x) for x in args.relay_range.split("-", 1))

    key = (SERVE / "pki" / "stream-ticket.key").read_bytes().strip()
    if not key:
        print("no stream-ticket key — the gate is off, nothing to check")
        return 0
    tiles = json.loads((SERVE / "tiles.json").read_text())

    failures: list[tuple[str, str]] = []
    pool: dict[str, dict[str, list[str]]] = {}
    checked = 0
    for name, info in sorted(tiles.items()):
        os_name = walkin_os(name)
        slots = pool.setdefault(os_name, {"live": [], "idle": [], "bad": []}) if os_name else None
        identity = daemon_identity(info.get("hashFile", ""))
        if identity is None:
            if slots is not None:
                slots["idle"].append(name)
            else:
                print(f"  SKIP  {name:<22} no signalling published (tile not running?)")
            continue
        checked += 1
        ok, why = check_one(key, name, identity)
        note = "" if name == identity else f"  (signal id {name!r} -> daemon {identity!r})"
        if lo is not None and not (lo <= (info.get("udpPort") or 0) <= hi):
            ok, why = False, f"udpPort {info.get('udpPort')} outside relay range {lo}-{hi}"
        if ok:
            if slots is not None:
                slots["live"].append(name)
            print(f"  ok    {name:<22} accepts its ticket{note}")
        else:
            if slots is not None:
                slots["bad"].append(name)
            failures.append((name, why))
            print(f"  FAIL  {name:<22} {why}{note}")

    report_pool(pool)

    print()
    if failures:
        print(f"{len(failures)} tile(s) would REFUSE every session:")
        for name, why in failures:
            print(f"  {name}: {why}")
        return 1
    print(f"all {checked} running tile(s) of {len(tiles)} accept their own tickets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
