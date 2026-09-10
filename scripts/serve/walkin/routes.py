"""The server side of `/walkin/state|claim|release|reset` (contract ledger §3).

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
    broker.access = access
    cookie = budget.cookie(user) if budget is not None else ""

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
        elif path == "/walkin/release":
            out = broker.release(uid, str(body.get("clone", "")))
            if budget is not None:
                budget.stopped(user)
            _reply(handler, 200, out, cookie)
        elif path == "/walkin/reset":
            _reply(handler, 200, broker.reset(uid, str(body.get("clone", ""))), cookie)
        else:
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


def user_id(user) -> str:
    if isinstance(user, dict):
        return str(user.get("id", ""))
    return str(getattr(user, "id", user))
