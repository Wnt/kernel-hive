"""The server side of `/walkin/state|claim|engage|release|reset` (ledger §3).

**This module does not decide who may call it.** Lane 2 owns the walk-in role,
the access switch and the ticket gate in `scripts/serve/auth/`; by the time
`dispatch` runs, `user` is whoever the session says it is and `access` is the
effective position of the switch (env floor already applied). What lives here is
the half that touches clones.

Ownership is still enforced — but as a fact about the pool, not as an auth
decision: `release` and `reset` name a clone, and the broker refuses one that is
not the caller's. A route that trusted the caller's word about which clone was
theirs would let any signed-in walk-in reset a stranger's session.
"""

from __future__ import annotations

import json
import secrets

PREFIX = "/walkin/"
BODY_CAP = 16 * 1024
JSON_TYPE = "application/json"

# ---------------------------------------------------------------------------
#  THE API, BY EXACT PATH — and the one place it is written down.
#
#  `dispatch` claims the whole `/walkin/` prefix, but `/walkin`,
#  `/walkin/play/<os>` and `/walkin/exhibits` are CLIENT-side routes that must
#  fall through to the SPA index, so something upstream has to know which paths
#  are ours. That something is `serve/walkin_plane.py`, and until 2026-09-11 it
#  kept its OWN tuple of four paths. `/walkin/engage` shipped with a handler
#  below and an entry in `auth/gate.py`'s anonymous allowlist, and 404ed on the
#  live box for every visitor, because the third list was never updated. Three
#  files had to agree and two of them did.
#
#  So there is one list now, it lives beside the handlers it names, and
#  `walkin_plane.API` is assigned FROM it rather than repeating it. The guard in
#  `dispatch` reads it too, which is what keeps it from becoming decorative: a
#  path missing here is refused here as well, so it cannot half-work.
# ---------------------------------------------------------------------------

#: Read with GET.
GET_PATHS = ("/walkin/state",)
#: Written with POST. Everything that changes a visitor's hold on a clone.
POST_PATHS = ("/walkin/claim", "/walkin/engage", "/walkin/release", "/walkin/reset")
#: Every exact path this module answers. `walkin_plane.API` is this tuple.
PATHS = GET_PATHS + POST_PATHS


class Refused(Exception):
    """A claim turned away for a reason the SPA renders its own copy for.

    Distinct from `BrokerError` because the body is different: a refusal
    carries the machine-readable code AND the state that explains it, so the
    client can put up the right wall without a second round trip.
    """

    def __init__(self, code: str, detail: dict | None = None):
        super().__init__(code)
        self.code = code
        self.detail = detail or {}


def _reply(handler, code: int, obj: dict, cookie: str = "") -> None:
    body = json.dumps(obj).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", JSON_TYPE)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    if cookie:
        handler.send_header("Set-Cookie", cookie)
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(body)


def random_station(broker) -> str:
    """A station picked uniformly at random among enabled pools.

    `os` is OPTIONAL on a claim, which is how a stranger "gets a machine"
    without first having to know what an OS/2 is. Pools with a free clone are
    preferred so the common answer is an instant one; when everything is busy
    the pick falls back to the whole enabled set, which puts the visitor in a
    queue rather than answering an error they cannot act on.

    `secrets.choice` rather than `random.choice`: same uniform draw, and it
    keeps a predictable-sequence question from ever needing to be asked about a
    surface strangers can call.
    """
    pools = [p for p in broker.pools() if int(p.get("size", 0) or 0) > 0]
    free = [p["os"] for p in pools if int(p.get("free", 0) or 0) > 0]
    if free:
        return secrets.choice(free)
    if pools:
        return secrets.choice([p["os"] for p in pools])
    raise Refused("walkin_no_pool", {})


def _body(handler) -> dict:
    body, err = handler.read_json_body(BODY_CAP)
    if err:
        return {}
    return body or {}


def dispatch(handler, path: str, method: str, broker, user, access: str, budget=None) -> bool:
    """Handle a `/walkin/*` request. Returns False if the path is not ours.

    `budget` is the second duck-typed collaborator this module takes, beside the
    broker: it answers how long THIS caller may hold a clone and whether they
    may have one at all (`auth/anon_plane.py`). It is optional, and None means
    exactly what it always meant — every caller gets the pool's own TTL. The
    role model stays where it was; this package still never asks who anyone is.
    """
    if not path.startswith(PREFIX):
        return False
    if path not in PATHS:
        # Not ours. In the serving process this is unreachable — `walkin_plane`
        # filters on the same tuple before calling — and that is the point: the
        # two layers cannot disagree about what the API is, because they are
        # reading the same list.
        _reply(handler, 404, {"error": "no such endpoint"})
        return True
    broker.access = access
    # The anonymous identity is planted ONLY by a request that BINDS something.
    # A read binds nothing, and the landing page fires TWO `GET /walkin/state`
    # polls concurrently on a cold jar: while the read stamped a cookie too,
    # each poll minted its OWN id and whichever response landed last won the
    # jar. That orphaned the id `POST /walkin/claim` had just recorded the
    # clone against, so `gate.anon_allows` no longer recognised the caller as
    # its holder and answered 401 on the visitor's own signalling document —
    # measured on the public gallery 2026-09-11 04:23:36 (walkin-os2warp-4:
    # granted, then five 401s and a `connect-giveup`, and the visitor's next
    # claim worked instantly). A read must never manufacture an identity.
    cookie = budget.cookie(user) if (budget is not None and method == "POST") else ""

    if path == "/walkin/state" and method == "GET":
        doc = broker.state()
        if user:
            ended = broker.session_end(user_id(user))
            if ended:
                # Two spellings of one fact, because lane 4 scans whatever it is
                # handed for the frozen code words: `sessionEnd` is the ledger
                # §3.3 message, `closeReason` the bare code beside it.
                doc["sessionEnd"] = ended
                doc["closeReason"] = ended["reason"]
        if budget is not None:
            block = budget.block(user)
            if block is not None:
                # Present ONLY for an anonymous caller, per the landing
                # contract: a signed-in visitor has no countdown to mirror.
                doc["anon"] = block
        _reply(handler, 200, doc, cookie)
        return True

    if method != "POST":
        _reply(handler, 405, {"error": "method not allowed"})
        return True

    if access == "closed":
        # The ledger's one specified HTTP error body. Same shape whichever of
        # the three write routes was asked for: mid-session or not, the plane is
        # shut and there is nothing useful to distinguish.
        _reply(handler, 403, {"error": "walkin_closed"}, cookie)
        return True

    if not user:
        _reply(handler, 401, {"error": "sign in first"})
        return True

    body = _body(handler)
    uid = user_id(user)
    try:
        if path == "/walkin/claim":
            _reply(handler, 200, _claim(broker, user, uid, body, budget), cookie)
        elif path == "/walkin/engage":
            _reply(handler, 200, _engage(broker, user, uid, body, budget), cookie)
        elif path == "/walkin/release":
            out = broker.release(uid, str(body.get("clone", "")))
            if budget is not None:
                budget.stopped(user)
            _reply(handler, 200, out, cookie)
        elif path == "/walkin/reset":
            _reply(handler, 200, broker.reset(uid, str(body.get("clone", ""))), cookie)
        else:  # pragma: no cover - PATHS and the chain above are checked in step
            _reply(handler, 404, {"error": "no such endpoint"})
    except Refused as exc:
        # The code is repeated as `reason` because the SPA scans for the frozen
        # code words wherever they arrive (§3.3), and `error` is also the human
        # string on every other refusal here.
        _reply(handler, 403, {"error": exc.code, "reason": exc.code, **exc.detail}, cookie)
    except Exception as exc:
        # Terse on purpose, like the auth surface: a walk-in learns that their
        # claim failed, not which internal path it failed on.
        message = str(exc)
        _reply(handler, 403 if message == "walkin_closed" else 400, {"error": message}, cookie)
    return True


def _claim(broker, user, uid: str, body: dict, budget) -> dict:
    """One claim, in the order the budget makes correct.

    The clock is started BEFORE the broker is asked, and the number it returns
    is the TTL the session is built with — see `anon_plane.AnonPlane` for why
    the other order silently destroys the machine a visitor was about to be
    offered. A claim that ends up queued or raises settles the clock again, so
    a failed attempt costs a round trip rather than a minute.
    """
    if budget is not None:
        refused = budget.refuse(user)
        if refused:
            raise Refused(refused, {"anon": budget.block(user)})
        # A visitor who has just registered gets the machine that was being
        # held for them, whatever `os` says — that screen is why they registered.
        resumed = budget.adopt(broker, user)
        if resumed is not None:
            return resumed
    station = str(body.get("os", "") or "").strip() or random_station(broker)
    ttl = budget.grant(user, station) if budget is not None else None
    try:
        out = broker.claim(uid, station, ttl)
    except Exception:
        if budget is not None:
            budget.stopped(user)
        raise
    if budget is not None:
        budget.granted(user, out)
    return out


def _engage(broker, user, uid: str, body: dict, budget) -> dict:
    """The visitor touched their machine — the one signal that starts a minute.

    It exists because the two clocks that bound a walk-in were both counted
    from the CLAIM, and a page that claims on load spends them on a stranger who
    is still reading the headline. So the browser reports the first real press,
    tap or key ON THE GUEST (`landing/heroPolicy.ts MEANINGFUL_EVENTS` — never a
    mouse crossing the picture), and this is where that lands.

    Two clocks move, and they are deliberately different clocks:

      * `Broker.note_input` restamps the session's idle window. It has had no
        production caller since it was written, which is why `holds.py` records
        that the "idle" reap was really a second TTL counted from the claim.
        This is that caller: from here on an idle walk-in is one who has stopped
        driving, which is what the number was always supposed to mean.
      * `budget.engage` starts the anonymous minute. It is the ONLY thing that
        does, and the server keeps the clock — the page reports an event, never
        a duration, and cannot report itself more time.

    OWNERSHIP IS CHECKED, and not as ceremony: `note_input` names a clone and
    takes no user, so an unchecked route would let any caller hold any
    stranger's session out of the idle reap. The broker's own answer to "which
    clone is this caller's" is the only one trusted here — never the body's.
    """
    clone = str(body.get("clone", "") or "").strip()
    own = broker.own_of(uid) or {}
    if not clone or clone != str(own.get("clone", "") or ""):
        raise Refused("walkin_not_yours", {})
    broker.note_input(clone)
    out = {"ok": True}
    if budget is not None:
        block = budget.engage(broker, user)
        if block is not None:
            out["anon"] = block
    return out


def user_id(user) -> str:
    if isinstance(user, dict):
        return str(user.get("id", ""))
    return str(getattr(user, "id", user))
