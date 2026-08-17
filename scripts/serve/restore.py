"""POST /restore/<osId> — reset ONE station to its golden fixture. No token
required: the endpoint is LAN-gated and non-destructive (reset-tile.sh only
loadvm-restores or cold-boots; it never runs savevm), so the exhibit's
"Restore to golden" button works for any visitor. RESTORE_ENABLE is the
operator's off-lever; the allowed-osId set (golden-manifest keys) bounds
which stations it can touch.
"""

from __future__ import annotations

import json
import subprocess
import sys

from config import GOLDEN_MANIFEST, RESET_SCRIPT, RESTORE_ENABLE
from static_files import MIME


def _restore_osids() -> set:
    """The osIds the button may restore = keys of golden-manifest.json."""
    try:
        return set(json.loads(GOLDEN_MANIFEST.read_text()).get("tiles", {}).keys())
    except Exception as e:
        sys.stderr.write(f"[serve] golden manifest unreadable: {e}\n")
        return set()


def handle_restore(handler, osid):
    if not RESTORE_ENABLE:
        return handler._send(403, json.dumps({"error": "restore disabled"}), MIME[".json"], cache=False)
    allowed = _restore_osids()
    if not osid or osid not in allowed:
        return handler._send(404, json.dumps({"error": "unknown osId", "osId": osid}), MIME[".json"], cache=False)
    if not RESET_SCRIPT.is_file():
        return handler._send(
            500,
            json.dumps({"error": "reset script missing", "path": str(RESET_SCRIPT)}),
            MIME[".json"],
            cache=False,
        )
    try:
        # reset-tile.sh handles loadvm (fast) and restart (cold-boot, slow);
        # give it room. It prints one status line and exits 0 on success.
        proc = subprocess.run(
            ["/bin/bash", str(RESET_SCRIPT), osid],
            capture_output=True,
            text=True,
            timeout=180,
        )
        ok = proc.returncode == 0
        detail = (proc.stdout or proc.stderr or "").strip()
        sys.stderr.write(f"[serve] restore {osid}: rc={proc.returncode} {detail}\n")
        code = 200 if ok else 500
        return handler._send(
            code,
            json.dumps(
                {
                    "ok": ok,
                    "osId": osid,
                    "detail": detail,
                }
            ),
            MIME[".json"],
            cache=False,
        )
    except subprocess.TimeoutExpired:
        return handler._send(
            504, json.dumps({"ok": False, "osId": osid, "error": "reset timed out"}), MIME[".json"], cache=False
        )
    except Exception as e:
        return handler._send(500, json.dumps({"ok": False, "osId": osid, "error": str(e)}), MIME[".json"], cache=False)
