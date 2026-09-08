"""One visitor's hold on one clone: the session policy numbers, the record, and
the two wire shapes built from it (contract ledger §3 claim body, §3.3 end).

Split out of `broker.py` on 2026-09-08 when the idempotent re-claim pushed it
over the 600-line cap; nothing here takes the broker's lock or touches a
hypervisor, which is what makes it the clean cut.
"""

from __future__ import annotations

from dataclasses import dataclass

TTL_SECONDS = 20 * 60
IDLE_SECONDS = 3 * 60
EXTENSION_SECONDS = 10 * 60
ACTIVE_SESSION_CAP = 6
CLOSE_REASON_TTL = "WALKIN_TTL"
CLOSE_REASON_IDLE = "WALKIN_IDLE"
CLOSE_REASON_CLOSED = "WALKIN_CLOSED"
CLOSE_MEMORY = 15 * 60  # how long a closed session's reason stays answerable
SESSION_END_TYPE = "session-end"  # ledger §3.3


def session_end_message(reason: str) -> dict:
    """The ledger §3.3 wire shape. One function so every road emits it alike."""
    return {"type": SESSION_END_TYPE, "reason": reason}


@dataclass
class Session:
    identity: str
    station: str
    user_id: str
    started_at: float
    expires_at: float
    last_input_at: float

    def ttl_left(self, now: float) -> int:
        return max(0, int(self.expires_at - now))


def claim_body(session: Session, now: float, resumed: bool = False) -> dict:
    """The §3 claim body. `resumed` marks a re-attach to a clone the visitor
    already held -- the TTL is what was LEFT on it, never a fresh one."""
    out = {
        "clone": session.identity,
        "signalEndpoint": f"/signal/{session.identity}.json",
        "ttlSeconds": session.ttl_left(now),
    }
    if resumed:
        out["resumed"] = True
    return out
