"""POST /clientlog — the untokened LAN/VPN browser telemetry sink. Body is one
JSON event object or an ARRAY of events; each is appended as one JSONL line
(+srvTs, +ip) to CLIENTLOG. Retention is a rolling window pruned by age, with
CLIENTLOG_MAX as a runaway size backstop.
"""

from __future__ import annotations

import contextlib
import json
import os
import sys
import threading
import time

from config import CLIENTLOG, CLIENTLOG_BODY_MAX, CLIENTLOG_MAX, CLIENTLOG_RETENTION_SECS
from static_files import MIME

# One lock guards clientlog append/rotate AND clientcmd read-modify-write:
# ThreadingHTTPServer runs one thread per connection, so both are concurrent.
log_lock = threading.Lock()

# Whitelisted client-supplied event fields -> stored key. The client's "ts"
# is stored as "clientTs" so it can never shadow the server-side timestamp.
_CLIENTLOG_FIELDS = (
    ("ts", "clientTs"),
    ("clientTs", "clientTs"),
    ("sessionId", "sessionId"),
    ("tile", "tile"),
    ("ua", "ua"),
    ("event", "event"),
    ("detail", "detail"),
    ("message", "message"),
    ("stack", "stack"),
    ("source", "source"),
    ("lineno", "lineno"),
    ("colno", "colno"),
    ("href", "href"),
    ("componentStack", "componentStack"),
)
_CLIENTLOG_STR_MAX = 512  # per-field truncation (detail, ua, ...)
_CLIENTLOG_LONG_FIELDS = frozenset(("stack", "componentStack"))
_CLIENTLOG_LONG_STR_MAX = 4096


def _clientlog_record(ev: dict, client: str) -> dict:
    """One JSONL record: srvTs + ip (server truth) + whitelisted client fields,
    strings truncated so a misbehaving client cannot bloat the log."""
    rec = {"srvTs": round(time.time(), 3), "ip": client}
    for src, dst in _CLIENTLOG_FIELDS:
        v = ev.get(src)
        if v is None:
            continue
        if isinstance(v, str):
            limit = _CLIENTLOG_LONG_STR_MAX if src in _CLIENTLOG_LONG_FIELDS else _CLIENTLOG_STR_MAX
            v = v[:limit]
        elif not isinstance(v, (int, float, bool)):
            v = str(v)[:_CLIENTLOG_STR_MAX]
        rec[dst] = v
    return rec


def _clientlog_prune_by_age(path, cutoff):
    """Rewrite `path` in place keeping only records with srvTs >= cutoff.

    Returns the number of rows dropped, or None if the file was left alone.
    Unparseable/timestamp-less rows are KEPT: this prunes by age, and a row we
    cannot date is not evidence we are entitled to throw away.
    """
    tmp = path.with_name(path.name + ".prune")
    kept = dropped = 0
    try:
        with open(path, encoding="utf-8", errors="replace") as src, open(tmp, "w", encoding="utf-8") as dst:
            for line in src:
                try:
                    ts = json.loads(line).get("srvTs")
                except (ValueError, AttributeError):
                    ts = None
                if isinstance(ts, (int, float)) and ts < cutoff:
                    dropped += 1
                    continue
                dst.write(line)
                kept += 1
        os.replace(tmp, path)
        return dropped
    except OSError as e:
        sys.stderr.write(f"[serve] clientlog prune failed: {e}\n")
        with contextlib.suppress(OSError):
            tmp.unlink()
        return None


def _clientlog_append(records):
    """Append records under the lock, pruning to the rolling retention window.

    Age-prune first (cheap, keeps the working file inside the window); only if
    that still leaves the file over the size backstop do we rotate a single .1
    generation, so a runaway client cannot fill the disk.
    """
    with log_lock:
        try:
            if CLIENTLOG.exists() and CLIENTLOG.stat().st_size > CLIENTLOG_MAX:
                cutoff = time.time() - CLIENTLOG_RETENTION_SECS
                dropped = _clientlog_prune_by_age(CLIENTLOG, cutoff)
                if dropped:
                    sys.stderr.write(
                        f"[serve] clientlog pruned {dropped} rows older than {CLIENTLOG_RETENTION_SECS}s\n"
                    )
                # Still oversized after pruning => the window itself is too big
                # for the disk budget; fall back to the generational rotate.
                if CLIENTLOG.stat().st_size > CLIENTLOG_MAX:
                    os.replace(CLIENTLOG, CLIENTLOG.with_name(CLIENTLOG.name + ".1"))
        except OSError as e:
            sys.stderr.write(f"[serve] clientlog rotate failed: {e}\n")
        with open(CLIENTLOG, "a", encoding="utf-8") as f:
            for rec in records:
                f.write(json.dumps(rec, separators=(",", ":")) + "\n")


def handle_post(handler):
    """POST /clientlog route body: read + validate the event batch, append it."""
    client = handler.client_address[0] if handler.client_address else ""
    obj, err = handler._read_json_body(CLIENTLOG_BODY_MAX)
    if err:
        return handler._send(err[0], json.dumps({"error": err[1]}), MIME[".json"], cache=False)
    events = obj if isinstance(obj, list) else [obj]
    if not events or not all(isinstance(e, dict) for e in events):
        return handler._send(
            400,
            json.dumps({"error": "expected an event object or an array of event objects"}),
            MIME[".json"],
            cache=False,
        )
    _clientlog_append([_clientlog_record(e, client) for e in events])
    return handler._send(200, '{"ok":true}', MIME[".json"], cache=False)
