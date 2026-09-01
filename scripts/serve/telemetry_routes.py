"""The analytics plane's four routes, dispatched as a group.

WHY THIS EXISTS. `osgallery-https-server.py` sits on the repo's 600-line hard
cap (scripts/check-file-size.mjs) and the analytics work added four routes to
it across three parallel branches. Each one fit on its own; together they did
not, and the merge — not any of the branches — is what breached the cap. The
fix is the shape the file already uses for the two other route families it
carries (`auth.routes.dispatch`, `walkin_plane.dispatch`): one `dispatch()` the
handler calls, returning True when it answered.

WHY THE ORIGIN CHECK IS HERE AND NOT PER-ROUTE. Both POSTs need it and both
need it for the same reason, so it is written once. On the public listener a
session cookie has already been required by `_public_gate`; the Origin header is
the second half of that — no other site gets to spend a visitor's cookie writing
into a table the lab makes decisions from. The LAN listener has neither notion
and needs neither. Getting this wrong on ONE of two routes is exactly the class
of mistake a shared dispatcher removes.

NO IDENTITY IS READ ON EITHER ROUTE, on either listener. That is not an
oversight to be corrected later: `serve/analytics.py` and `serve/linecov.py`
both store none by construction, and a route that looked one up would be the
first step in undoing that.
"""

from __future__ import annotations

import json
from urllib.parse import parse_qs, urlparse

import eum_proxy
import linecov
import logs
import probes
import traces
from static_files import MIME

import analytics


def _bad_origin(handler, public_origin: str) -> bool:
    """True (and the refusal already sent) when a public POST is cross-origin."""
    if handler.public and handler.headers.get("Origin") != public_origin:
        handler._send(403, json.dumps({"error": "bad origin"}), MIME[".json"], cache=False)
        return True
    return False


def dispatch(handler, path: str, method: str, stores: dict, public_origin: str) -> bool:
    """Answer one of the analytics routes. Returns True when it did."""
    # /eum — the Instana beacon proxy. Answered before the method split
    # because it owns EVERY method on its path: falling through on a GET would
    # hand the SPA fallback back to a vendor agent, which is a worse answer
    # than a 405. Its own module carries the origin check, the fence and the
    # queue; see eum_proxy.py for the whole posture. It is NOT one of the four
    # routes this file's docstring is about — it stores nothing here, reads no
    # identity, and is deletable with the rest of the Instana integration.
    if path == eum_proxy.PATH:
        eum_proxy.dispatch(handler, method, public_origin)
        return True

    if method == "POST":
        # POST /analytics — one tab's feature-reach / flow / error counters.
        if path == "/analytics":
            if _bad_origin(handler, public_origin):
                return True
            analytics.handle_post(handler, stores["analytics"])
            return True

        # POST /coverage — one instrumented tab's line map, once, at pagehide.
        # A normal gallery bundle never posts here: it does not carry the
        # collector at all (docs/ANALYTICS.md §7).
        if path == "/coverage":
            if _bad_origin(handler, public_origin):
                return True
            linecov.handle_post(handler, stores["coverage"])
            return True

        # POST /traces — one tab's OTel spans. Open like the others: a visitor
        # must be able to report a trace of the journey that just broke without
        # holding the admin session needed to READ one back.
        if path == "/traces":
            if _bad_origin(handler, public_origin):
                return True
            obj, err = handler._read_json_body(traces.BODY_MAX)
            if err:
                handler._send(err[0], json.dumps({"error": err[1]}), MIME[".json"], cache=False)
                return True
            n = stores["traces"].record(obj) if isinstance(obj, dict) else 0
            handler._send(200, json.dumps({"ok": True, "spans": n}), MIME[".json"], cache=False)
            return True

        # POST /logs — severity-bearing records from any of the three
        # producers: this plane's own sink, a station daemon's spool (shipped
        # by trace-ship.py), and the browser. Open for exactly the reason
        # /traces is: a tab has to be able to report the error that just broke
        # its visit without holding the admin session needed to READ one back.
        # Reads live behind /auth/logs/* (serve/logs_read.py).
        if path == "/logs":
            if _bad_origin(handler, public_origin):
                return True
            obj, err = handler._read_json_body(logs.BODY_MAX)
            if err:
                handler._send(err[0], json.dumps({"error": err[1]}), MIME[".json"], cache=False)
                return True
            n = stores["logs"].record(obj) if isinstance(obj, dict) else 0
            handler._send(200, json.dumps({"ok": True, "logs": n}), MIME[".json"], cache=False)
            return True
        return False

    if method == "GET":
        # GET /analytics/report.json — feature reach, funnels and top errors.
        # No identities in it, so it needs no more of a gate than
        # /usage/stations.json does.
        if path == "/analytics/report.json":
            # Fold the server's own pending counts in first: they are throttled
            # to a flush a minute on the request path, and a report that omitted
            # the last minute would read as a branch that had gone quiet.
            probes.flush()
            query = parse_qs(urlparse(handler.path).query)
            analytics.serve_report(handler, stores["analytics"], query)
            return True

        # GET /coverage/report.json — production line coverage, per file.
        if path == "/coverage/report.json":
            query = parse_qs(urlparse(handler.path).query)
            linecov.serve_report(handler, stores["coverage"], query)
            return True
    return False
