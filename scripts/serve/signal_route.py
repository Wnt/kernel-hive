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

# The walk-in pool, bound by the server at startup (contract ledger §3.1). A
# clone is not in tiles.json — it exists for twenty minutes — so its signaling
# row comes from the broker instead, in tiles.json's own shape. Both stay None
# on a box with no walk-in plane, and every path below degrades to what it did
# before the plane existed.
BROKER = None
WALKIN_TICKETS = None


def bind_walkin(broker, tickets=None) -> None:
    """Wire the pool broker (and its ticket registry) into the signaling path."""
    global BROKER, WALKIN_TICKETS
    BROKER = broker
    WALKIN_TICKETS = tickets


def _pool_rows() -> dict:
    """`{identity: {udpPort, hashFile}}` for the live pool members, or `{}`."""
    if BROKER is None:
        return {}
    try:
        return BROKER.signal_entries()
    except Exception as e:  # noqa: BLE001 — the fleet's own signaling must survive it
        sys.stderr.write(f"[serve] walk-in pool rows unavailable: {e}\n")
        return {}


def load_tiles():
    """Read the tiles config fresh each request so edits need no restart.

    The walk-in pool is merged on top: a clone answers `/signal/<clone>.json`
    exactly the way a station answers its own, which is what lets one stream
    client serve both. Pool identities are `walkin-<os>-<n>` (ledger §5.1) and
    cannot collide with a registry id, which the station registry forbids.
    """
    try:
        tiles = json.loads(SIGNAL_CONFIG.read_text())
    except Exception as e:
        sys.stderr.write(f"[serve] tiles config unreadable: {e}\n")
        tiles = {}
    tiles.update(_pool_rows())
    return tiles


def serve_index(handler):
    tiles = load_tiles()
    out = {t: {"udpPort": v.get("udpPort")} for t, v in tiles.items()}
    return handler._send(200, json.dumps(out), MIME[".json"], cache=False)


def serve_tile(handler, tile, stream_key):
    tiles = load_tiles()
    info = tiles.get(tile)
    if not info:
        # A reaped clone is GONE, not unknown, and the difference is the whole
        # point: the client that lost its transport re-fetches this document
        # first, and a bare 404 here is exactly the "connection lost" lie the
        # §3.3 reason codes exist to prevent. 410 carries the honest answer —
        # the clock, the idle window, or the switch.
        ended = BROKER.session_end_for_clone(tile) if BROKER is not None else None
        if ended:
            return handler._send(410, json.dumps({**ended, "tile": tile}), MIME[".json"], cache=False)
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
        # A walk-in clone's ticket is minted through the registry that can
        # REVOKE it: dropping the switch to Closed must make a ticket already in
        # a browser useless before the clones die, or a disconnected client
        # re-handshakes into the machine it was just removed from (brief §5.1).
        # A station's ticket stays stateless, as it has always been.
        if WALKIN_TICKETS is not None and tile in _pool_rows():
            body["path"] = WALKIN_TICKETS.mint(stream_key, ticket_tile)
        else:
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
