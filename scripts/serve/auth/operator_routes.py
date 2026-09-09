"""The box-side operator surface: `/auth/invite/issue`.

Separate module, not folded into routes.py, because routes.py is the
browser-facing `/auth/*` surface — every handler in there is reached through
`dispatch`, which enforces the Origin check a same-origin browser tab always
sends. This route has no browser tab: it exists so a box-side script
(`scripts/dev/sim-invite-rotate.sh`) can mint a viewer invite for automation
without a human completing a passkey ceremony, gated EXACTLY like
`/clientcmd/admin` — loopback peer AND the operator token
(`osgallery-https-server.py`'s `_require_box_side` / `_admin_identity`) — and
never reachable from the public listener (nothing here is dispatched unless
`self.public` is false).
"""

from __future__ import annotations

import json
import sys

from .service import AuthError

BODY_CAP = 64 * 1024
JSON = "application/json"


def handle_issue_invite(handler, service) -> None:
    """POST /auth/invite/issue — mint a viewer invite, no admin session.

    `handler._require_box_side` is the SAME gate `/clientcmd/admin` uses
    (loopback peer AND `X-Admin-Token`) — same failure status, same reason
    string, same denial log line. The identity it hands back is never a
    secret and is used only for the log line below, never stored as the
    invite's `createdBy` (that is always the fixed `"operator:clientcmd"`, so
    an issued invite can never be mistaken for one an admin account created).
    """
    if not handler._require_box_side("invite issue"):
        return
    admin_identity = handler._admin_identity()

    body, err = handler.read_json_body(BODY_CAP)
    if err:
        _reply(handler, err[0], {"error": err[1]})
        return
    body = body or {}

    role = str(body.get("role", "viewer"))
    if role != "viewer":
        _reply(handler, 400, {"error": "role must be viewer"})
        return

    name = str(body.get("name", ""))
    ttl_days_raw = body.get("ttlDays")
    ttl_days = None
    if ttl_days_raw is not None:
        try:
            ttl_days = int(ttl_days_raw)
        except (TypeError, ValueError):
            _reply(handler, 400, {"error": "ttlDays must be an integer"})
            return

    try:
        result = service.create_operator_invite(name, ttl_days)
    except AuthError as exc:
        _reply(handler, exc.status, {"error": str(exc)})
        return

    # The code itself never reaches the log — only that one was minted, for
    # whom, at what role and lifetime, same discipline as the clientcmd audit
    # trail's "a valid token was presented, never which one".
    sys.stderr.write(
        f"[serve] invite issued by={admin_identity} name={result['name']!r} "
        f"role={result['role']} expiresAt={result['expiresAt']}\n"
    )
    _reply(handler, 200, result)


def _reply(handler, code: int, obj: dict) -> None:
    body = json.dumps(obj).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", JSON)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(body)
