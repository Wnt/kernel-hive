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

# Spans (serve/tracing.py); see the note on the same import in signal_route.py.
try:
    import tracing
except ImportError:  # pragma: no cover - import shape only
    from serve import tracing


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
    # A visitor pressed "Restore to golden" and is now watching a black tile.
    # This span is the only place that says which of the two things happened —
    # a `loadvm` measured in a second or two, or a cold boot measured in
    # minutes — and it says it per station, which is what turns "restore feels
    # slow" into a golden worth recapturing. The subprocess OUTPUT is
    # deliberately not an attribute: it is arbitrary text from a shell script,
    # and a span may not carry that. The return code is the whole verdict.
    with tracing.child("serve.restore.reset", {"kh.station": osid}) as span:
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
            span.end("ok" if ok else "error", {"kh.restore.rc": proc.returncode})
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
            span.end("error", {"error.type": "resetTimedOut"})
            return handler._send(
                504, json.dumps({"ok": False, "osId": osid, "error": "reset timed out"}), MIME[".json"], cache=False
            )
        except Exception as e:
            span.record_exception(e)
            span.end("error")
            return handler._send(
                500, json.dumps({"ok": False, "osId": osid, "error": str(e)}), MIME[".json"], cache=False
            )
