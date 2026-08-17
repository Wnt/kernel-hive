"""Platform WebRTC signaling: the ICE-server config reader and the non-trickle
SDP offer proxy. Every station in SIGNAL_CONFIG routes to the ONE generic
loopback bridge by station id; SDP and ICE/TURN credentials are intentionally
never written to logs.
"""

from __future__ import annotations

import json
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

from config import WEBRTC_BRIDGE_UPSTREAM, WEBRTC_ICE_SERVERS_FILE, WEBRTC_OFFER_BODY_MAX
from static_files import MIME


def ice_servers():
    """Read platform ICE servers without ever logging credential contents."""
    try:
        doc = json.loads(WEBRTC_ICE_SERVERS_FILE.read_text())
        servers = doc.get("iceServers") if isinstance(doc, dict) else doc
        return servers if isinstance(servers, list) else []
    except FileNotFoundError:
        # Host/UDP is intentional while TURN is unavailable; absence is quiet.
        return []
    except Exception as e:
        sys.stderr.write(f"[serve] WebRTC ICE config unavailable ({type(e).__name__})\n")
        return []


def handle_offer(handler, tile, load_tiles):
    info = load_tiles().get(tile)
    if not isinstance(info, dict):
        return handler._send(404, json.dumps({"error": "unknown tile", "tile": tile}), MIME[".json"], cache=False)
    obj, err = handler._read_json_body(WEBRTC_OFFER_BODY_MAX)
    if err:
        return handler._send(err[0], json.dumps({"error": err[1]}), MIME[".json"], cache=False)
    if not isinstance(obj, dict) or obj.get("type") != "offer" or not isinstance(obj.get("sdp"), str):
        return handler._send(400, json.dumps({"error": "expected SDP offer"}), MIME[".json"], cache=False)
    parsed = urlparse(WEBRTC_BRIDGE_UPSTREAM)
    if (
        parsed.scheme != "http"
        or parsed.hostname not in ("127.0.0.1", "::1", "localhost")
        or parsed.query
        or parsed.fragment
    ):
        return handler._send(
            500, json.dumps({"error": "WebRTC upstream must be loopback HTTP"}), MIME[".json"], cache=False
        )
    upstream = f"{WEBRTC_BRIDGE_UPSTREAM}/offer/{quote(tile, safe='')}"
    try:
        req = Request(
            upstream,
            data=json.dumps(obj).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(req, timeout=15) as response:
            body = response.read(WEBRTC_OFFER_BODY_MAX)
            status = response.status
        sys.stderr.write(f"[serve] WebRTC offer tile={tile} upstream_status={status}\n")
        return handler._send(status, body, MIME[".json"], cache=False)
    except HTTPError as e:
        detail = e.read(4096).decode("utf-8", errors="replace")
        sys.stderr.write(f"[serve] WebRTC offer tile={tile} upstream_status={e.code}\n")
        return handler._send(e.code, detail, MIME[".json"], cache=False)
    except (URLError, TimeoutError, OSError) as e:
        sys.stderr.write(f"[serve] WebRTC offer tile={tile} upstream_error={type(e).__name__}\n")
        return handler._send(
            502, json.dumps({"error": "WebRTC platform bridge unavailable"}), MIME[".json"], cache=False
        )
