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


class WalkinTickets:
    """The outstanding walk-in tickets, so the switch can revoke them.

    An ordinary ticket is stateless — an HMAC over `tile|exp|nonce` that the
    verifier checks with no lookup — which is exactly what a kill switch cannot
    live with: step 2 of dropping to Closed must make a ticket already handed to
    a browser useless BEFORE the clones are killed, or a disconnected client
    re-handshakes into the clone it was just removed from (brief §5.1).

    So walk-in tickets, and only walk-in tickets, are minted through here and
    remembered. `revoke_all` forgets them and stamps a cutoff; `is_live` is what
    the signaling path asks before it hands a browser a clone again.

    WHAT THIS DOES NOT DO, stated plainly: it does not reach into streamhost's
    verifier. A ticket already in a browser's hands stays cryptographically
    valid until it expires (DEFAULT_TTL_SECS, 5 minutes). What actually ends
    that session is step 4 — the clone is killed, so there is nothing left to
    present it to. This registry closes the re-handshake door in front of it.
    """

    def __init__(self):
        import threading

        self._lock = threading.Lock()
        self._live: dict[str, tuple[str, int]] = {}
        self.revoked_before = 0

    def mint(self, key: bytes, clone: str, ttl_secs: int = DEFAULT_TTL_SECS) -> str:
        path = mint(key, clone, ttl_secs)
        nonce = path.split("/")[-1].split(".")[1]
        with self._lock:
            self._expire()
            self._live[nonce] = (clone, int(time.time()) + ttl_secs)
        return path

    def is_live(self, path_or_nonce: str) -> bool:
        nonce = path_or_nonce.split(".")[1] if path_or_nonce.startswith("/wt/") else path_or_nonce
        with self._lock:
            self._expire()
            return nonce in self._live

    def outstanding(self) -> list[str]:
        """The clones with a live ticket, for check-stream-tickets.py."""
        with self._lock:
            self._expire()
            return sorted({clone for clone, _ in self._live.values()})

    def revoke_all(self) -> int:
        with self._lock:
            count = len(self._live)
            self._live.clear()
            self.revoked_before = int(time.time())
            return count

    def revoke_clone(self, clone: str) -> int:
        with self._lock:
            gone = [n for n, (c, _) in self._live.items() if c == clone]
            for nonce in gone:
                del self._live[nonce]
            return len(gone)

    def _expire(self) -> None:
        t = int(time.time())
        self._live = {n: v for n, v in self._live.items() if v[1] > t}
