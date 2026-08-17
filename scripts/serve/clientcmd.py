"""Operator command plane: GET /clientcmd (polling) and POST /clientcmd/admin
(enqueue). Token-gated (X-Admin-Token vs CLIENTCMD_TOKEN, read fresh per
request) — see handler._require_admin for the passkey-session fallback used
on the public listener.
"""

from __future__ import annotations

import hmac
import json
import os
import sys
import time

from clientlog import CLIENTLOG_BODY_MAX, log_lock
from config import CLIENTCMD, CLIENTCMD_ALLOWED, CLIENTCMD_KEEP, CLIENTCMD_TOKEN, OSG_ADMIN_EVAL
from static_files import MIME


def _clientcmd_load() -> dict:
    """Read the command queue fresh per request (load_tiles() idiom: hand-edits
    over ssh need no restart). Missing/corrupt file == empty queue."""
    try:
        doc = json.loads(CLIENTCMD.read_text())
        if not isinstance(doc, dict):
            raise ValueError("queue root is not an object")
        doc["seq"] = int(doc.get("seq", 0))
        cmds = doc.get("cmds")
        doc["cmds"] = [c for c in cmds if isinstance(c, dict)] if isinstance(cmds, list) else []
        return doc
    except FileNotFoundError:
        return {"seq": 0, "cmds": []}
    except Exception as e:
        sys.stderr.write(f"[serve] clientcmd queue unreadable: {e}\n")
        return {"seq": 0, "cmds": []}


def _clientcmd_save(doc: dict):
    """Atomic write (tmp + os.replace) so pollers never see a torn file."""
    tmp = CLIENTCMD.with_name(CLIENTCMD.name + ".tmp")
    tmp.write_text(json.dumps(doc, separators=(",", ":")))
    os.replace(tmp, CLIENTCMD)


def _clientcmd_token_ok(presented) -> bool:
    """Constant-time check against the token file, read fresh per request.
    Missing/empty token file fails CLOSED (endpoint unusable until minted)."""
    try:
        want = CLIENTCMD_TOKEN.read_text().strip()
    except Exception:
        return False
    if not want or not presented:
        return False
    return hmac.compare_digest(want, presented.strip())


def handle_poll(handler, since_qs):
    """GET /clientcmd?since=<seq> route body."""
    try:
        since = int(since_qs[0]) if since_qs else 0
    except ValueError:
        since = 0
    doc = _clientcmd_load()
    cmds = [c for c in doc["cmds"] if int(c.get("seq", 0)) > since]
    if not OSG_ADMIN_EVAL:
        # A stale queue written during a prior opt-in must never execute
        # after the server returns to its default-safe configuration.
        cmds = [c for c in cmds if c.get("cmd") != "eval"]
    out = {"seq": doc["seq"], "cmds": cmds}
    return handler._send(200, json.dumps(out), MIME[".json"], cache=False)


def handle_admin_post(handler):
    """POST /clientcmd/admin route body: enqueue a command for polling UI tabs."""
    obj, err = handler._read_json_body(CLIENTLOG_BODY_MAX)
    if err:
        return handler._send(err[0], json.dumps({"error": err[1]}), MIME[".json"], cache=False)
    if not isinstance(obj, dict):
        return handler._send(400, json.dumps({"error": "expected a command object"}), MIME[".json"], cache=False)
    cmd = obj.get("cmd")
    if cmd not in CLIENTCMD_ALLOWED:
        return handler._send(
            400,
            json.dumps({"error": "unknown cmd", "allowed": list(CLIENTCMD_ALLOWED)}),
            MIME[".json"],
            cache=False,
        )
    if cmd == "eval" and not OSG_ADMIN_EVAL:
        return handler._send(
            403,
            json.dumps({"error": "eval disabled; set OSG_ADMIN_EVAL=1 explicitly"}),
            MIME[".json"],
            cache=False,
        )
    tile = obj.get("tile") or "*"
    # Preserve the complete args object unchanged in the queue. In
    # particular, eval requires args.code and optional args.sessionId.
    args = obj.get("args") or {}
    if not isinstance(tile, str) or not isinstance(args, dict):
        return handler._send(
            400, json.dumps({"error": "tile must be a string, args an object"}), MIME[".json"], cache=False
        )
    with log_lock:
        doc = _clientcmd_load()
        doc["seq"] += 1
        doc["cmds"].append(
            {"seq": doc["seq"], "ts": round(time.time(), 3), "cmd": cmd, "tile": tile[:64], "args": args}
        )
        doc["cmds"] = doc["cmds"][-CLIENTCMD_KEEP:]
        _clientcmd_save(doc)
        seq = doc["seq"]
    sys.stderr.write(f"[serve] clientcmd enqueued seq={seq} {cmd} tile={tile}\n")
    return handler._send(200, json.dumps({"ok": True, "seq": seq}), MIME[".json"], cache=False)
