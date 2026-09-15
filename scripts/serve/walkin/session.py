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
# Matches the pool's total warm capacity (3 stations x poolSize 8, raised
# 2026-09-10 alongside poolSize from a cap of 6). At this value the cap stops
# being the backstop that ever refuses a visitor a free member on its own --
# concurrent TCG load on the box is the real ceiling below it, not this number.
ACTIVE_SESSION_CAP = 24
# ---------------------------------------------------------------------------
#  THE HOLD WINDOW — "about five minutes", and the ONE place it is written.
#
#  A visitor who leaves a machine does not lose it: switching freezes it (vCPUs
#  stopped, `walkin/holds.py`) and reserves it for THAT visitor for this long,
#  so wandering from Win 3.11 to OS/2 and back finds the Win 3.11 desktop
#  exactly as it was. The same number is the conversion wall's hold — the
#  stranger who ran out of budget and is being asked to make a passkey gets
#  their machine back if they register inside it — because they are the same
#  promise from the visitor's side ("your machine waits ~5 minutes") and a
#  visitor who registered at 4:30 into a hold must not find the wall opening
#  onto a machine a SHORTER wall timer had already destroyed. `auth/anon.py`
#  imports this rather than keeping the second copy it used to have (120 s).
#
#  Approximate on purpose: the reaper enforces it on `Broker.tick`, and the
#  watchdog sleeps on `next_expiry`, so the real window is this plus a tick.
HOLD_SECONDS = 5 * 60
# How many FROZEN machines one visitor may reserve at once, on top of the one
# they are driving. Two, because the landing page offers exactly three machines
# (win311, os2warp, rhapsody) and the whole point is that a visitor may try all
# three and find each as they left it — so the ceiling is "all of them" for the
# intended tour and a real ceiling for anything beyond it. It is a RESOURCE
# ceiling, not a policy nicety: every hold is a slot, a UDP port, a tap, a VMID
# and a core that no other visitor can be handed, so an unbounded version of
# this feature is a pool one crawler can empty by cycling stations. Over the
# ceiling, the OLDEST hold is destroyed — the machine they left longest ago is
# the one they are least likely to be coming back to.
MAX_HOLDS_PER_VISITOR = 2
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
    # Set once, by `Holding.retime` (walkin/holds.py), the instant an anonymous
    # visitor's budget clock starts. From there this session's whole remaining
    # life IS the anonymous budget — `AnonPlane.enforce` already polices it,
    # every tick, ahead of `Broker.tick` itself, freezing rather than
    # destroying at the exact deadline. The ordinary idle window is a second,
    # SHORTER bound with nothing keeping it fresh once `engage()` has fired its
    # one signal (`note_input` has no other caller), which was harmless only
    # while the budget stayed under it. `expires_at` is still an unconditional
    # backstop either way, so this never leaves a session unbounded.
    idle_exempt: bool = False
    # The last instant this session was the visitor's FOREGROUND machine: set
    # when it is claimed or thawed, and again when it is frozen (the moment it
    # stopped being in front of them). With several sessions per visitor it is
    # the only ordering that answers "the last machine they were on" — which is
    # what the conversion wall must hand back, and what decides which hold is
    # evicted at the ceiling. `started_at` cannot: a thaw keeps the clone's
    # original clock, and `last_input_at` is a liveness stamp the idle reaper
    # owns.
    used_at: float = 0.0
    # The same ordering, made EXACT. `used_at` is a clock reading, and two of
    # them can be equal: a switch freezes the outgoing machine and the wall can
    # freeze the incoming one inside the same instant the broker read once. On
    # a tie `max()` keeps the FIRST it saw, so the conversion wall handed back
    # the machine the visitor had left EARLIEST — the opposite of the promise,
    # and caught by `test_holds.test_the_wall_hands_back_the_machine_they_were
    # _on_not_an_older_hold` before it ever reached a visitor. A counter the
    # broker bumps on every freeze cannot tie, whatever the clock's resolution.
    used_seq: int = 0

    def ttl_left(self, now: float) -> int:
        return max(0, int(self.expires_at - now))


def claim_body(session: Session, now: float, resumed: bool = False) -> dict:
    """The §3 claim body. `resumed` marks a re-attach to a clone the visitor
    already held -- the TTL is what was LEFT on it, never a fresh one.

    `station` is here because `os` is OPTIONAL on a claim: a visitor who asks
    for a random machine has no other way to learn which one they got."""
    out = {
        "clone": session.identity,
        "station": session.station,
        "signalEndpoint": f"/signal/{session.identity}.json",
        "ttlSeconds": session.ttl_left(now),
    }
    if resumed:
        out["resumed"] = True
    return out
