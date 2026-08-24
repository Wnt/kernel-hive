"""Interaction counters: how much each visitor used the gallery, and which
machines the fleet actually gets used on.

WHAT IS COUNTED. One click is one BUTTON-DOWN edge the browser put on the wire;
one keystroke is one KEY-DOWN edge. Releases, moves, wheel and the repeat storm
a held key produces are not counted — a scoreboard wants deliberate acts, and
counting both edges would simply double every number.

WHERE THE COUNT COMES FROM. The input plane is WebTransport straight from the
tab to streamhost's QUIC listener; it never passes through this server, and the
ticket that gates it carries a station and an expiry but no identity. So the
counter has to live where the events are, which is the tab, and be reported
here. That makes these numbers a visitor's own account of what they did: good
enough for a private gallery's scoreboard, and NOT an audit trail. The batch
caps below bound how far a forged report can move a total; nothing bounds a
patient liar, and nothing needs to.

TWO PLANES, ON PURPOSE. `stations` is an aggregate — how much a machine is used,
by nobody in particular — and is what the fleet table reads; every session may
see it, and it is what survives when a person is deleted. `users` is per-person
and is served ONLY to an admin, from a separate endpoint. A viewer holding a
session has no route to any of it: the split is in the storage, not just in the
UI, so a future careless render cannot leak what it never received.

THIS IS NOT THE ACCOUNT DATABASE. It lives in its own file for the same reason:
auth-state.json is irreplaceable (delete it and every enrolled passkey is locked
out forever — 2026-08-05), and a counter written every few seconds has no
business sharing a file with it.
"""

from __future__ import annotations

import atexit
import json
import os
import re
import threading
import time
from pathlib import Path

# A station id as the registry writes it (stations-registry.py enforces the same
# shape). The tab supplies this, so it is validated rather than trusted.
STATION_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,39}$")
# Per-report caps. A tab flushes every ~20 s; a human cannot honestly produce
# more than a few hundred edges in that window, and no station spans more than a
# handful of tiles in one flush.
MAX_STATIONS_PER_REPORT = 32
MAX_EDGES_PER_REPORT = 5000
# Ceiling on distinct station ids ever tracked, so a stream of junk ids cannot
# grow the file without bound. The fleet is 63 entries; this is far above it.
MAX_STATIONS_TRACKED = 500
# Counters are written at most this often. A crash loses at most this much
# counting, which is the right thing to trade for not fsync-ing per click.
WRITE_MIN_SECS = 10


def _now() -> int:
    return int(time.time())


def _iso(ts: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def _blank() -> dict:
    return {"clicks": 0, "keys": 0}


class UsageStore:
    """The interaction counters. Every public method is safe from any thread."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self._lock = threading.RLock()
        self._doc = self._read()
        self._dirty = False
        self._last_write = 0.0
        atexit.register(self.flush)

    # ---- persistence -------------------------------------------------------

    def _read(self) -> dict:
        try:
            doc = json.loads(self.path.read_text())
        except FileNotFoundError:
            doc = {}
        except Exception:
            # Unlike the auth state, losing this file costs a scoreboard and
            # nothing else — so a corrupt one starts over rather than keeping
            # the gallery down.
            doc = {}
        doc.setdefault("version", 1)
        doc.setdefault("stations", {})
        doc.setdefault("users", {})
        return doc

    def flush(self) -> None:
        """Write now if anything is pending. Called on exit and by the throttle."""
        with self._lock:
            if not self._dirty:
                return
            tmp = self.path.with_suffix(".tmp")
            self.path.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as fh:
                json.dump(self._doc, fh, indent=2, sort_keys=True)
                fh.write("\n")
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, self.path)
            self._dirty = False
            self._last_write = time.monotonic()

    def _mark_dirty(self) -> None:
        self._dirty = True
        if time.monotonic() - self._last_write >= WRITE_MIN_SECS:
            self.flush()

    # ---- intake ------------------------------------------------------------

    def record(self, user_id: str | None, counts: dict) -> int:
        """Fold one tab's report in. Returns how many edges were accepted.

        `counts` is {station: {"clicks": n, "keys": n}} as the tab reported it.
        A report with no user (the LAN listener has no sessions at all) still
        moves the station aggregate: the machine was used, and by whom is a
        question only the public edge can answer.
        """
        if not isinstance(counts, dict):
            return 0
        taken = 0
        t = _now()
        with self._lock:
            for station, raw in list(counts.items())[:MAX_STATIONS_PER_REPORT]:
                if not isinstance(station, str) or not STATION_RE.match(station):
                    continue
                if not isinstance(raw, dict):
                    continue
                clicks = _clamp(raw.get("clicks"))
                keys = _clamp(raw.get("keys"))
                if not clicks and not keys:
                    continue
                stations = self._doc["stations"]
                if station not in stations and len(stations) >= MAX_STATIONS_TRACKED:
                    continue
                self._fold(stations.setdefault(station, _blank()), clicks, keys, t)
                if user_id:
                    user = self._doc["users"].setdefault(user_id, {"clicks": 0, "keys": 0, "stations": {}})
                    user.setdefault("firstAt", _iso(t))
                    self._fold(user, clicks, keys, t)
                    self._fold(user["stations"].setdefault(station, _blank()), clicks, keys, t)
                taken += clicks + keys
            if taken:
                self._mark_dirty()
        return taken

    @staticmethod
    def _fold(bucket: dict, clicks: int, keys: int, t: int) -> None:
        bucket["clicks"] = int(bucket.get("clicks", 0)) + clicks
        bucket["keys"] = int(bucket.get("keys", 0)) + keys
        bucket["lastAt"] = _iso(t)

    # ---- reading -----------------------------------------------------------

    def stations(self) -> dict:
        """The per-station aggregate. Carries no identities by construction —
        this is the document the fleet table fetches, on both listeners."""
        with self._lock:
            return {"stations": {k: dict(v) for k, v in self._doc["stations"].items()}}

    def scoreboard(self, users: list[dict]) -> dict:
        """Per-person rows, joined to the names only an admin caller may see.

        Driven by the USER list, not by the counter file: somebody who has never
        clicked belongs on the scoreboard with a zero, and a counter row whose
        user is gone belongs nowhere (forget_user removes it, and this is the
        belt to that braces).
        """
        with self._lock:
            rows = []
            for u in users:
                rec = self._doc["users"].get(u["id"]) or {}
                stations = {k: dict(v) for k, v in (rec.get("stations") or {}).items()}
                rows.append(
                    {
                        "userId": u["id"],
                        "name": u["name"],
                        "role": u["role"],
                        "clicks": int(rec.get("clicks", 0)),
                        "keys": int(rec.get("keys", 0)),
                        "lastAt": rec.get("lastAt"),
                        "lastSeenAt": u.get("lastSeenAt"),
                        "stations": stations,
                    }
                )
            rows.sort(key=lambda r: r["clicks"] + r["keys"], reverse=True)
            return {"users": rows, "stations": {k: dict(v) for k, v in self._doc["stations"].items()}}

    def forget_user(self, user_id: str) -> None:
        """Drop one person's counters. Their contribution to the station
        aggregate stays: it is not theirs, it is the machine's."""
        with self._lock:
            if self._doc["users"].pop(user_id, None) is not None:
                self._dirty = True
                self.flush()


def _clamp(value) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        return 0
    return min(value, MAX_EDGES_PER_REPORT)


# ---- HTTP glue -------------------------------------------------------------
# Kept here rather than in the server module for the same reason clientlog's is:
# the route is two lines of framing around one store call.

#: A report is a small flat object; anything larger than this is not one.
USAGE_BODY_MAX = 4096


def handle_post(handler, store: UsageStore, user_id: str | None) -> None:
    """POST /usage — one tab's batch of interaction counts.

    `user_id` is the caller's session identity or None. On the LAN listener it
    is always None (there are no sessions there at all) and the report still
    counts toward the station aggregate.
    """
    from static_files import MIME

    obj, err = handler._read_json_body(USAGE_BODY_MAX)
    if err:
        return handler._send(err[0], json.dumps({"error": err[1]}), MIME[".json"], cache=False)
    if not isinstance(obj, dict):
        return handler._send(400, json.dumps({"error": "expected an object"}), MIME[".json"], cache=False)
    taken = store.record(user_id, obj.get("stations") or {})
    return handler._send(200, json.dumps({"ok": True, "counted": taken}), MIME[".json"], cache=False)


def serve_stations(handler, store: UsageStore) -> None:
    """GET /usage/stations.json — the per-station aggregate, no identities.

    Reachable by any session (and openly on LAN, like every other lab document):
    it is how much each machine is used, by nobody in particular. The per-person
    half lives behind /auth/usage/report and never travels this route.
    """
    from static_files import MIME

    return handler._send(200, json.dumps(store.stations()), MIME[".json"], cache=False)
