#!/usr/bin/env python3
"""Verify that every tile's signalling doc carries a ticket that tile will accept.

RUN ON THE BOX:  python3 /data/vms/streamhost/serve/check-stream-tickets.py

The gateway signs a stream ticket over the tile's identity, and streamhost
verifies it against its own `SH_TILE`. Those are two different sources for one
name, and they do not always agree: the SPA calls one exhibit `solaris` while
its daemon runs as `solariscde` (likewise `aros`/`amigaos`). On 2026-08-05 the
gateway signed with the SPA's name, so both tiles refused every session with
`bad signature` — they streamed for a moment on an already-open session, then
went dead the next time a client reconnected, which reads to a visitor as "it
froze after I clicked".

Nothing detected it: the tile was up, the daemon was healthy, the signalling doc
looked perfect, and the failure lived in the relationship between two documents.
So this checks the relationship — it recomputes each ticket's HMAC exactly as
the daemon does and reports the tiles that would refuse a connection.

Exit 0 = every tile would accept its own ticket.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import ssl
import sys
import urllib.request
from pathlib import Path

SERVE = Path("/data/vms/streamhost/serve")
GATEWAY = "https://127.0.0.1:8443"


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


def main() -> int:
    key = (SERVE / "pki" / "stream-ticket.key").read_bytes().strip()
    if not key:
        print("no stream-ticket key — the gate is off, nothing to check")
        return 0
    tiles = json.loads((SERVE / "tiles.json").read_text())

    failures = []
    for name, info in sorted(tiles.items()):
        identity = daemon_identity(info.get("hashFile", ""))
        if identity is None:
            print(f"  SKIP  {name:<14} no signalling published (tile not running?)")
            continue
        try:
            doc = gateway_signal(name)
        except Exception as exc:  # noqa: BLE001 — any failure here is a failure to report
            failures.append((name, f"gateway: {type(exc).__name__}"))
            print(f"  FAIL  {name:<14} gateway said {type(exc).__name__}")
            continue
        ticket = doc.get("path")
        if not ticket:
            failures.append((name, "no ticket minted"))
            print(f"  FAIL  {name:<14} signalling carries no ticket")
            continue
        ok, why = verify(key, ticket, identity)
        note = "" if name == identity else f"  (signal id {name!r} -> daemon {identity!r})"
        if ok:
            print(f"  ok    {name:<14} accepts its ticket{note}")
        else:
            failures.append((name, why))
            print(f"  FAIL  {name:<14} {why}{note}")

    print()
    if failures:
        print(f"{len(failures)} tile(s) would REFUSE every session:")
        for name, why in failures:
            print(f"  {name}: {why}")
        return 1
    print(f"all {len(tiles)} tiles accept their own tickets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
