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

PREFIX = "/walkin/"
BODY_CAP = 16 * 1024
JSON_TYPE = "application/json"


def _reply(handler, code: int, obj: dict) -> None:
    body = json.dumps(obj).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", JSON_TYPE)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(body)


def _body(handler) -> dict:
    body, err = handler.read_json_body(BODY_CAP)
    if err:
        return {}
    return body or {}


def dispatch(handler, path: str, method: str, broker, user, access: str) -> bool:
    """Handle a `/walkin/*` request. Returns False if the path is not ours."""
    if not path.startswith(PREFIX):
        return False
    broker.access = access

    if path == "/walkin/state" and method == "GET":
        doc = broker.state()
        if user:
            reason = broker.close_reason(user_id(user))
            if reason:
                doc["closeReason"] = reason
        _reply(handler, 200, doc)
        return True

    if method != "POST":
        _reply(handler, 405, {"error": "method not allowed"})
        return True

    if access == "closed":
        # The ledger's one specified HTTP error body. Same shape whichever of
        # the three write routes was asked for: mid-session or not, the plane is
        # shut and there is nothing useful to distinguish.
        _reply(handler, 403, {"error": "walkin_closed"})
        return True

    if not user:
        _reply(handler, 401, {"error": "sign in first"})
        return True

    body = _body(handler)
    uid = user_id(user)
    try:
        if path == "/walkin/claim":
            _reply(handler, 200, broker.claim(uid, str(body.get("os", ""))))
        elif path == "/walkin/release":
            _reply(handler, 200, broker.release(uid, str(body.get("clone", ""))))
        elif path == "/walkin/reset":
            _reply(handler, 200, broker.reset(uid, str(body.get("clone", ""))))
        else:
            _reply(handler, 404, {"error": "no such endpoint"})
    except Exception as exc:
        # Terse on purpose, like the auth surface: a walk-in learns that their
        # claim failed, not which internal path it failed on.
        message = str(exc)
        _reply(handler, 403 if message == "walkin_closed" else 400, {"error": message})
    return True


def user_id(user) -> str:
    if isinstance(user, dict):
        return str(user.get("id", ""))
    return str(getattr(user, "id", user))
