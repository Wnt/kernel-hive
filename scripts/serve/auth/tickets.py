"""Stream tickets: the gateway half of streamhost's media-plane gate.

A tile's QUIC listener answers whoever reaches its UDP port, and a WebTransport
session carries the guest's INPUT plane as well as its video. On the LAN that is
fine. Once the port is published, it is the difference between a login that means
something and one that only hides the front door — so streamhost refuses any
session whose path does not carry a live ticket signed with the shared secret
(streamhost/src/session_ticket.rs is the verifier; keep the two in step).

The ticket rides the signaling doc's existing `path` field, which the SPA already
honours, so the browser needs no change at all.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import time

# Minutes, not hours: a ticket is minted per connect, spent immediately, and the
# UI re-fetches signaling on every reconnect. The verifier independently caps
# how far out an expiry may sit.
DEFAULT_TTL_SECS = 300


def mint(key: bytes, tile: str, ttl_secs: int = DEFAULT_TTL_SECS) -> str:
    """The WebTransport path a browser should connect to for this tile."""
    exp = int(time.time()) + ttl_secs
    # token_urlsafe emits exactly the alphabet the verifier accepts for a nonce.
    nonce = secrets.token_urlsafe(9)
    msg = f"v1|{tile}|{exp}|{nonce}".encode()
    sig = base64.urlsafe_b64encode(hmac.new(key, msg, hashlib.sha256).digest()).rstrip(b"=").decode("ascii")
    return f"/wt/{exp}.{nonce}.{sig}"
