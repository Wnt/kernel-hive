"""GET /signal/index.json and GET /signal/<tile>.json — the per-tile signaling
document read LIVE from the tile's streamhost cert-hash file, so cert
ROTATION is picked up with no restart.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from auth import tickets
from config import PUBLIC_HOST, SIGNAL_CONFIG, SIGNAL_HOST
from static_files import MIME
from webrtc import ice_servers


def load_tiles():
    """Read the tiles config fresh each request so edits need no restart."""
    try:
        return json.loads(SIGNAL_CONFIG.read_text())
    except Exception as e:
        sys.stderr.write(f"[serve] tiles config unreadable: {e}\n")
        return {}


def serve_index(handler):
    tiles = load_tiles()
    out = {t: {"udpPort": v.get("udpPort")} for t, v in tiles.items()}
    return handler._send(200, json.dumps(out), MIME[".json"], cache=False)


def serve_tile(handler, tile, stream_key):
    tiles = load_tiles()
    info = tiles.get(tile)
    if not info:
        return handler._send(404, json.dumps({"error": "unknown tile", "tile": tile}), MIME[".json"], cache=False)
    hashfile = info.get("hashFile")
    try:
        cert_hash = Path(hashfile).read_text().strip()
    except Exception:
        return handler._send(
            503, json.dumps({"error": "cert hash not ready", "tile": tile}), MIME[".json"], cache=False
        )
    body = {
        "host": SIGNAL_HOST,
        "udpPort": info.get("udpPort"),
        "certHashB64": cert_hash,
    }
    # The daemon publishes its own identity beside the cert hash, and it
    # is that identity — SH_STATION — that it verifies a ticket against, so
    # that is what the ticket is signed over. The endpoint key normally
    # equals it (the registry refuses an id that differs from its
    # stationDir), but they are two different documents and the daemon is
    # the authority on its own: signing with the endpoint key while
    # `solaris` still ran as `solariscde` and `aros` as `amigaos` locked
    # both stations out of every session for four hours on 2026-08-05. Read
    # the authority from the daemon; fall back to the key for a station that
    # has not published one yet.
    ticket_tile = tile
    signal_doc = None
    try:
        signal_doc = json.loads(Path(hashfile).with_name("signaling.json").read_text())
        ticket_tile = signal_doc.get("tile") or tile
    except Exception:
        pass
    # The stream ticket is minted for EVERY caller, LAN included: a station
    # with SH_SESSION_KEY set refuses an unticketed session from any
    # source, so making this public-only would take the LAN gallery down.
    # Reaching this endpoint is itself the authorization — open on the
    # LAN, session-gated on the public listener.
    if stream_key:
        body["path"] = tickets.mint(stream_key, ticket_tile)
    if handler.public:
        # Same station, same cert: WebTransport pins the certificate by
        # HASH, so the hostname it is reached under is not part of
        # verification. Only the route changes — the public relay host
        # instead of the LAN IP.
        body["host"] = PUBLIC_HOST
    # WebRTC is a platform capability for every station. The client enters
    # this path only when VideoDecoder is absent; WebCodecs-capable
    # clients ignore it and retain the WebTransport default.
    body["webrtc"] = {
        "offerUrl": f"/webrtc/{tile}/offer",
        "iceServers": ice_servers(),
        "jitterBufferTargetMs": 15,
    }
    # A restarted streamhost publishes its active QUIC policy beside
    # the cert hash (read above). Forward only that small optional
    # object so clients can report which MTU policy they actually
    # negotiated against; old/unrestarted stations simply omit it.
    if isinstance(signal_doc, dict) and isinstance(signal_doc.get("quic"), dict):
        body["quic"] = signal_doc["quic"]
    return handler._send(200, json.dumps(body), MIME[".json"], cache=False)
