"""The /auth/* HTTP surface, bolted onto the stdlib request handler.

Kept apart from the SPA server so the gallery's own routing stays readable and
this file can be reviewed as one thing: every request that changes who can get
in passes through `dispatch`.

Two cross-cutting rules live here rather than in each handler:

  * Every state-changing call must carry `Origin: <the gallery's origin>`.
    Session cookies are sent on cross-site POSTs by default in enough browsers
    that SameSite alone is not the whole answer; an origin check is, and it
    costs one comparison.
  * Errors are terse on purpose. "that code is not valid" covers expired,
    revoked, mistyped and never-existed, because distinguishing them out loud
    tells an attacker which half of the guess was right.
"""

from __future__ import annotations

import json
from http.cookies import SimpleCookie

from .service import AuthError

COOKIE_NAME = "osg_session"
BODY_CAP = 64 * 1024
JSON = "application/json"


def session_token(handler) -> str:
    raw = handler.headers.get("Cookie")
    if not raw:
        return ""
    try:
        jar = SimpleCookie()
        jar.load(raw)
    except Exception:
        return ""
    morsel = jar.get(COOKIE_NAME)
    return morsel.value if morsel else ""


def _reply(handler, code: int, obj: dict, cookie: str | None = None, clear_cookie: bool = False) -> None:
    body = json.dumps(obj).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", JSON)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    if cookie is not None:
        handler.send_header("Set-Cookie", _cookie_header(cookie))
    if clear_cookie:
        handler.send_header("Set-Cookie", f"{COOKIE_NAME}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax")
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(body)


def _cookie_header(token: str) -> str:
    # Secure even though this listener speaks plaintext: it is loopback-only,
    # behind the edge's TLS, so the browser's view of the connection is HTTPS.
    # SameSite=Lax rather than Strict so a link into the gallery arrives logged
    # in; the Origin check below is what actually stops cross-site writes.
    return f"{COOKIE_NAME}={token}; Path=/; Max-Age={30 * 24 * 3600}; HttpOnly; Secure; SameSite=Lax"


def _client_ip(handler) -> str:
    # Behind the edge, the socket peer is the tunnel. X-Forwarded-For is set by
    # our own Caddy, one hop away — good enough to rate-limit and to log, and
    # never used for authorization.
    fwd = handler.headers.get("X-Forwarded-For")
    if fwd:
        return fwd.split(",")[0].strip()
    return handler.client_address[0] if handler.client_address else "unknown"


def dispatch(handler, path: str, method: str, service, origin: str) -> bool:
    """Handle an /auth/* request. Returns False if the path is not ours."""
    if not path.startswith("/auth/"):
        return False

    user = service.user_for_token(session_token(handler))

    if path == "/auth/state" and method == "GET":
        _reply(handler, 200, service.public_state(user))
        return True

    if path == "/auth/walkin/status" and method == "GET":
        if not user or user["role"] != "admin":
            _reply(handler, 403, {"error": "admins only"})
        else:
            _reply(handler, 200, service.walkin.status())
        return True

    if method != "POST":
        _reply(handler, 405, {"error": "method not allowed"})
        return True

    sent = handler.headers.get("Origin")
    if sent != origin:
        _reply(handler, 403, {"error": "bad origin"})
        return True

    body, err = handler.read_json_body(BODY_CAP)
    if err and path not in ("/auth/logout", "/auth/login/begin", "/auth/passkeys/begin"):
        _reply(handler, err[0], {"error": err[1]})
        return True
    body = body or {}

    try:
        _route(handler, path, service, user, body)
    except AuthError as exc:
        _reply(handler, exc.status, {"error": str(exc)})
    return True


def _route(handler, path: str, service, user, body: dict) -> None:
    ip = _client_ip(handler)
    ua = handler.headers.get("User-Agent") or ""

    if path == "/auth/logout":
        service.store.drop_session(session_token(handler))
        _reply(handler, 200, {"ok": True}, clear_cookie=True)
        return

    # ---- getting in --------------------------------------------------------

    if path == "/auth/redeem/begin":
        cid, options = service.begin_redeem(str(body.get("code", "")), str(body.get("name", "")), ip)
        _reply(handler, 200, {"ceremonyId": cid, "publicKey": options})
        return

    if path == "/auth/redeem/finish":
        new_user, token = service.finish_redeem(str(body.get("ceremonyId", "")), body.get("credential") or {}, ip, ua)
        _reply(handler, 200, {"ok": True, "user": _public_user(new_user)}, cookie=token)
        return

    # An invite LINK: signs its holder in with no passkey at all, and says how
    # much of the invite is left so the page can nudge them to make one. The
    # passkey itself is then the ordinary /auth/passkeys/* pair below — by this
    # point they have a session, so there is nothing special left to do.
    if path == "/auth/invite/enter":
        entered, token, info = service.enter_invite(str(body.get("code", "")), ip, ua)
        _reply(handler, 200, {"ok": True, "user": _public_user(entered), **info}, cookie=token)
        return

    if path == "/auth/login/begin":
        cid, options = service.begin_login(ip)
        _reply(handler, 200, {"ceremonyId": cid, "publicKey": options})
        return

    if path == "/auth/login/finish":
        who, token = service.finish_login(str(body.get("ceremonyId", "")), body.get("credential") or {}, ip, ua)
        _reply(handler, 200, {"ok": True, "user": _public_user(who)}, cookie=token)
        return

    # ---- everything below needs a session ----------------------------------

    if not user:
        raise AuthError("sign in first", status=401)

    if path == "/auth/passkeys/begin":
        cid, options = service.begin_add_passkey(user)
        _reply(handler, 200, {"ceremonyId": cid, "publicKey": options})
        return

    if path == "/auth/passkeys/finish":
        cred = service.finish_add_passkey(str(body.get("ceremonyId", "")), body.get("credential") or {}, user, ua)
        _reply(handler, 200, {"ok": True, "passkey": {"id": cred["id"], "label": cred["label"]}})
        return

    if path == "/auth/passkeys/delete":
        service.delete_passkey(user, str(body.get("id", "")), is_admin=user["role"] == "admin")
        _reply(handler, 200, {"ok": True})
        return

    # Any signed-in user may link another of their own devices — this is not an
    # admin power, it is the ordinary way to stop depending on one phone.
    if path == "/auth/link/create":
        _reply(handler, 200, service.create_link(user))
        return

    if path == "/auth/me":
        _reply(
            handler,
            200,
            {
                "user": _public_user(user),
                "passkeys": [
                    {"id": c["id"], "label": c["label"], "createdAt": c["createdAt"], "lastUsedAt": c["lastUsedAt"]}
                    for c in service.store.credentials(user["id"])
                ],
            },
        )
        return

    # ---- admin only --------------------------------------------------------

    if user["role"] != "admin":
        raise AuthError("admins only", status=403)

    if path == "/auth/people":
        _reply(handler, 200, service.people())
        return

    # The per-PERSON scoreboard. It is admin-only by position — everything below
    # the role check above is — and, more to the point, by ROUTE: the counters a
    # viewer's own tab reports are folded into a per-station aggregate served
    # openly at /usage/stations.json, and into a per-user record that leaves the
    # box through this endpoint and no other.
    if path == "/auth/usage/report":
        _reply(handler, 200, service.scoreboard())
        return

    if path == "/auth/invites/create":
        _reply(handler, 200, service.create_invite(user, str(body.get("name", "")), str(body.get("role", "viewer"))))
        return

    if path == "/auth/invites/revoke":
        service.revoke_invite(str(body.get("id", "")))
        _reply(handler, 200, {"ok": True})
        return

    if path == "/auth/users/role":
        service.set_role(user, str(body.get("userId", "")), str(body.get("role", "")))
        _reply(handler, 200, {"ok": True})
        return

    if path == "/auth/users/delete":
        service.delete_user(user, str(body.get("userId", "")))
        _reply(handler, 200, {"ok": True})
        return

    # ---- the walk-in switch (ledger §3) ------------------------------------
    #
    # Under /auth/ rather than /walkin/ because it is an operator control, and
    # so it inherits this file's two cross-cutting rules unchanged: the Origin
    # check above, and the admin role check a few lines up.

    if path == "/auth/walkin/access":
        _reply(handler, 200, service.walkin.set_access(user, str(body.get("access", ""))))
        return

    if path == "/auth/walkin/drain":
        _reply(handler, 200, service.walkin.set_drain(user, bool(body.get("drain", True))))
        return

    if path == "/auth/walkin/purge":
        _reply(handler, 200, service.walkin.purge(int(body.get("olderThanDays") or 90)))
        return

    _reply(handler, 404, {"error": "no such endpoint"})


def _public_user(user: dict) -> dict:
    return {"id": user["id"], "name": user["name"], "role": user["role"]}


# ---- the walk-in surface ---------------------------------------------------


def dispatch_walkin(handler, path: str, method: str, service, origin: str, own=None) -> bool:
    """Handle the two /walkin/* routes that are auth's, not the broker's.

    Returns False for anything else, so the serving plane chains this in front
    of the broker's own dispatcher: `dispatch_walkin(...) or broker.dispatch(...)`.
    Signup and the manifest projection live here because both are decisions
    about WHO may see WHAT, which is this package's job; the pool is not.
    """
    if path not in ("/walkin/signup", "/walkin/signup/begin", "/walkin/signup/finish", "/walkin/manifest.json"):
        return False
    user = service.user_for_token(session_token(handler))

    if path == "/walkin/manifest.json":
        if method != "GET":
            _reply(handler, 405, {"error": "method not allowed"})
            return True
        try:
            service.walkin.require_reachable(user)
            _reply(handler, 200, service.walkin.manifest(own))
        except AuthError as exc:
            _reply(handler, exc.status, {"error": str(exc)})
        return True

    if method != "POST":
        _reply(handler, 405, {"error": "method not allowed"})
        return True
    if handler.headers.get("Origin") != origin:
        _reply(handler, 403, {"error": "bad origin"})
        return True
    body, err = handler.read_json_body(BODY_CAP)
    if err and path.endswith("/finish"):
        _reply(handler, err[0], {"error": err[1]})
        return True
    body = body or {}
    ip = _client_ip(handler)
    ua = handler.headers.get("User-Agent") or ""
    try:
        # The ledger names ONE signup route carrying "a WebAuthn attestation".
        # WebAuthn cannot be one round trip — the challenge has to come from the
        # server first — so /walkin/signup routes on the body: an attestation
        # finishes the ceremony, its absence begins one. The explicit
        # /begin + /finish pair is the same thing spelled out.
        if path != "/walkin/signup/finish" and not body.get("credential"):
            cid, options = service.walkin.begin_signup(ip)
            _reply(handler, 200, {"ceremonyId": cid, "publicKey": options})
        else:
            new_user, token, handle = service.walkin.finish_signup(
                str(body.get("ceremonyId", "")), body.get("credential") or {}, ip, ua
            )
            _reply(handler, 200, {"handle": handle, "role": new_user["role"]}, cookie=token)
    except AuthError as exc:
        _reply(handler, exc.status, {"error": str(exc)})
    return True
