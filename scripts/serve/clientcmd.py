"""The client command plane, split BY DIRECTION and gated per half.

GET /clientcmd (poll, the READ half) is reachable by ANY authenticated gallery
session — see handler._require_session. Remote debugging has to work for every
visitor, always; polling only reads the operator's queue and a tab acts on a
command only when it is addressed to that tab.

POST /clientcmd/admin (enqueue, the WRITE half) is what ISSUES a command and is
BOX-SIDE ONLY: 404 on the public listener (auth/gate.py BLOCKED_PREFIXES) and,
on the LAN listener, a loopback peer plus a valid X-Admin-Token — see
handler._require_box_side. No UI session has a path to issue a command.

Because of that, `eval` carries no second opt-in. The old default-off
OSG_ADMIN_EVAL=1 guarded a browser-reachable enqueue; with no such path it
protected nothing while making every live debugging session wait on a box-side
ritual that does not survive a reboot. It survives as an explicit DISABLE:
OSG_ADMIN_EVAL=0 shuts eval off.

Every accepted command is written to CLIENTCMD_AUDIT (clientcmd-audit.jsonl)
before it is queued: what, to whom, by which credential, from where, when.
"""

from __future__ import annotations

import hmac
import json
import os
import sys
import time

from clientlog import CLIENTLOG_BODY_MAX, log_lock
from config import (
    CLIENTCMD,
    CLIENTCMD_ALLOWED,
    CLIENTCMD_AUDIT,
    CLIENTCMD_KEEP,
    CLIENTCMD_TOKEN,
    OSG_ADMIN_EVAL,
)
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


def _audit(rec: dict):
    """Append one append-only audit row for an ISSUED command.

    This is the record of who pointed what at whom. It is deliberately a
    SEPARATE file from the telemetry sink: clientlog.jsonl is a rolling window
    that prunes itself by age, and an audit trail that quietly deletes itself is
    not an audit trail. It is never rotated here, and it never contains the
    operator token — only which KIND of credential authorized the command.
    """
    try:
        with open(CLIENTCMD_AUDIT, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    except OSError as e:
        sys.stderr.write(f"[serve] clientcmd audit write FAILED ({e}) for {rec.get('cmd')}\n")


def handle_poll(handler, since_qs):
    """GET /clientcmd?since=<seq> route body."""
    try:
        since = int(since_qs[0]) if since_qs else 0
    except ValueError:
        since = 0
    doc = _clientcmd_load()
    cmds = [c for c in doc["cmds"] if int(c.get("seq", 0)) > since]
    if not OSG_ADMIN_EVAL:
        # eval has been explicitly disabled: a queue written before that must
        # never keep executing afterwards.
        cmds = [c for c in cmds if c.get("cmd") != "eval"]
    out = {"seq": doc["seq"], "cmds": cmds}
    return handler._send(200, json.dumps(out), MIME[".json"], cache=False)


def handle_admin_post(handler, issued_by=None):
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
            json.dumps({"error": "eval is disabled on this server (OSG_ADMIN_EVAL=0)"}),
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
    code = args.get("code")
    target_session = args.get("sessionId")
    _audit(
        {
            "srvTs": round(time.time(), 3),
            "seq": seq,
            "cmd": cmd,
            "tile": tile[:64],
            "sessionId": str(target_session)[:64] if target_session else None,
            # For eval the code IS the audit record; bound it so one huge
            # payload cannot dominate the file.
            "code": code[:2048] if isinstance(code, str) else None,
            "issuedBy": issued_by or "unknown",
            # Every authenticated tab polls, so a "*" command with no sessionId
            # reaches every open session. Worth stating plainly in the record.
            "broadcast": tile == "*" and not target_session,
            "peer": handler.client_address[0] if handler.client_address else "",
            "listener": "public" if handler.public else "lan",
        }
    )
    sys.stderr.write(
        f"[serve] clientcmd enqueued seq={seq} {cmd} tile={tile} "
        f"session={target_session or '*'} by={issued_by or 'unknown'}\n"
    )
    return handler._send(200, json.dumps({"ok": True, "seq": seq}), MIME[".json"], cache=False)
