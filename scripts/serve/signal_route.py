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
from probes import hit
from static_files import MIME

# Spans (serve/tracing.py). Two module names for one module — see probes.py.
# Unlike the probes import there is no third no-op fallback: `tracing` is in the
# same static box-sync list as this file and scripts/lint/deploy-pair-imports.py
# fails the build if a paired file imports an unpaired module, so "deployed
# without it" is not a state this plane can reach.
try:
    import tracecontext
    import tracing
except ImportError:  # pragma: no cover - import shape only
    from serve import tracecontext, tracing
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
    # THE TRACE ID THE DAEMON JOINS BY (docs/lab/TRACE-CONTEXT.md §3). The input
    # plane is WebTransport straight to the station's own QUIC listener and
    # carries no headers, so there is no hop on which to put a `traceparent`.
    # This request — the signalling fetch the tab makes before it connects — is
    # therefore where the session's trace id is decided: the browser's when it
    # sent one, a fresh one when it did not. Recording it as an attribute makes
    # the join key EXPLICIT in the data rather than implicit in the span's own
    # id, so an operator holding a daemon-side id can search for it directly.
    # The ticket itself is never recorded: the ticket carries the trace id, the
    # trace never carries the ticket.
    request = tracing.current()
    request.attr("kh.session.traceId", request.trace_id)
    # Where signalling latency actually goes, part one: reading tiles.json off
    # disk and merging the walk-in broker's live pool rows on top. Both are done
    # fresh per request on purpose, and a broker under its own lock is the
    # plausible stall.
    with tracing.child("serve.signal.load", {"kh.station": tile}):
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
    # Part two: the daemon's published cert hash. A station that has not written
    # it yet is the 503 below, and this span is what says whether that 503 was
    # instant (no file) or a slow read on a loaded box.
    with tracing.child("serve.signal.certhash", {"kh.station": tile}) as certspan:
        try:
            cert_hash = Path(hashfile).read_text().strip()
        except Exception:
            certspan.end("error", {"error.type": "certHashNotReady"})
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
        if ticket_tile != tile:
            # The fallback is doing real work RIGHT NOW: this document's key and
            # the daemon's own name disagree, and every ticket for this station
            # is being signed over the daemon's. That is correct behaviour and it
            # is also a latent four-hour outage the registry is supposed to make
            # impossible, so a non-zero here is a station to go and look at.
            hit("signal.ticket.identityDiffers")
            # The counter says how often; the span says WHICH station, right
            # now, in a trace an operator is already looking at. A station id is
            # public in the gallery manifest, so this carries nothing private.
            request.attr("kh.station.identity", ticket_tile)
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
        # Which of the two ticket paths a station got, and what it cost. The
        # walk-in path takes the registry lock and expires old nonces; the
        # station path is a stateless HMAC. Only the KIND is recorded — the
        # ticket is a credential and never goes in a span.
        with tracing.child("serve.ticket.mint", {"kh.station": ticket_tile}) as mintspan:
            if WALKIN_TICKETS is not None and tile in _pool_rows():
                mintspan.attr("kh.ticket.kind", "walkin")
                body["path"] = WALKIN_TICKETS.mint(stream_key, ticket_tile)
            else:
                mintspan.attr("kh.ticket.kind", "station")
                body["path"] = tickets.mint(stream_key, ticket_tile)
            # The daemon's half of the trace (docs/lab/TRACE-CONTEXT.md §3.1).
            # The input plane is raw WebTransport with no headers, so the id
            # rides the ticket's query string — which the HMAC does not cover
            # and `session_ticket.rs::verify` has always split off before
            # verifying, so appending it neither invalidates a ticket nor lets
            # a tampered query forge one.
            #
            # This is the span the whole trace hangs from: it is the id the
            # BROWSER will see in its signalling document and the id the DAEMON
            # will stamp on its session, so recording it here is what lets one
            # visit be one trace across three processes.
            body["path"] += "?traceparent=" + tracecontext.format(mintspan.trace_id, mintspan.span_id)
            mintspan.attr("kh.session.traceId", mintspan.trace_id)
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
