"""Freezing a session in place, and handing the same machine to an account.

The pool's founding invariant is that **a clone is never handed to a second
visitor** — a session ends, the machine is destroyed, the next visitor's comes
off the golden. This module does not weaken that. It adds the one case where a
machine outlives the session that was on it *for the same human*: the anonymous
stranger who has just run out of their sixty seconds and is being asked to make
a passkey.

Recycling their clone at that moment would make the ask hollow. The strongest
argument the museum has for registering is the screen already in front of them —
the DOS prompt they typed into, the window they dragged — so the wall goes up
over a machine that is merely **stopped**, and registering resumes it. Two
minutes later, if nobody came back, it is destroyed like any other.

Three things this has to get right, and each is a way the feature could be
decorative instead of real:

  * **Frozen means the vCPUs are stopped**, not "the UI stopped drawing". The
    visitor's WebTransport session is still open — streamhost checks its ticket
    once, at `req.accept()` (`transport/mod.rs`), and never again — so the only
    thing that can actually stop them driving is the guest not executing. That
    is also, for free, the frozen last frame the wall wants behind it.
  * **The ticket door shuts first, and shuts even if the pause fails.** The
    freeze is recorded under the broker lock BEFORE any QMP round trip, so
    `ticket_ttl_for` answers 0 from that instant on; a pause that then fails is
    not survivable and the session is destroyed outright rather than left
    running behind a wall.
  * **The idle reap must not eat the hold.** `last_input_at` is written by
    `POST /walkin/engage` (`walkin/routes.py::_engage`) and by nothing else, so
    for a visitor who never touches the guest the 180-second "idle" window is
    still a second, shorter TTL counted from the claim. A hold set at T+60 would
    be reaped at T+180 by that clock instead of by its own. Freezing therefore
    restamps `last_input_at`, which is the only honest thing to do with it: the
    visitor is not idle, they are stopped.
"""

from __future__ import annotations

import sys

from .session import CLOSE_REASON_CLOSED, CLOSE_REASON_TTL, claim_body, session_end_message
from .warm import BrokerError


class Holding:
    """Mixin on `Broker`. Every method takes the broker's own lock; none of them
    holds it across a QMP round trip."""

    #: identity -> the instant it was frozen. Lazily created so that `Broker`'s
    #: constructor needs no line for it, and so that the map cannot become a
    #: class-level default shared between brokers.
    _frozen: dict | None = None

    @property
    def frozen(self) -> dict:
        if self._frozen is None:
            self._frozen = {}
        return self._frozen

    def is_frozen(self, identity: str) -> bool:
        """Whether this clone is stopped behind a wall. Stale entries — a clone
        already destroyed — answer False and are swept by `next_expiry`."""
        with self._lock:
            return identity in self.frozen and identity in self._members

    def freeze(self, user_id: str, hold_secs: float) -> str:
        """Stop this visitor's machine and reserve it for `hold_secs`.

        Returns the clone identity, or "" if they held nothing. The clone stays
        a member with its session attached, which is what keeps it out of every
        free count and out of every other visitor's claim.
        """
        with self._lock:
            session = self._session_of(user_id)
            if session is None:
                return ""
            identity = session.identity
            member = self._members.get(identity)
            if member is None:
                return ""
            now = self._now()
            # The ticket door, shut before anything can fail.
            self.frozen[identity] = now
            session.expires_at = now + float(hold_secs)
            # See the module docstring: the idle window is a second TTL counted
            # from the claim, and a hold must not be reaped by it.
            session.last_input_at = now
            clone = member.clone
        try:
            clone.pause()
        except Exception as exc:  # noqa: BLE001 — a hold we cannot enforce is not a hold
            sys.stderr.write(
                f"[walkin] {identity} would not pause behind the wall "
                f"({type(exc).__name__}: {exc}) — destroying it instead\n"
            )
            with self._lock:
                self.frozen.pop(identity, None)
            try:
                self.release(user_id, identity, "")
            except Exception as why:  # noqa: BLE001 — reported; the reaper is the backstop
                sys.stderr.write(f"[walkin] and it would not release either: {why}\n")
            return ""
        return identity

    def reassign(self, from_user: str, to_user: str, ttl: float) -> dict | None:
        """Hand a frozen machine to the account its visitor just registered.

        The clone does not change; only whose it is, and for how long. That is
        the entire point of the hold — the work on the screen is the reason the
        passkey was worth making.
        """
        with self._lock:
            session = self._session_of(from_user)
            if session is None:
                return None
            identity = session.identity
            member = self._members.get(identity)
            if member is None:
                return None
            now = self._now()
            session.user_id = to_user
            session.started_at = now
            session.expires_at = now + float(ttl)
            session.last_input_at = now
            was_frozen = self.frozen.pop(identity, None) is not None
            self._closes.pop(from_user, None)
            body = claim_body(session, now, resumed=True)
            clone = member.clone
        if was_frozen:
            try:
                clone.resume()
            except Exception as exc:  # noqa: BLE001 — reported, never a 500 for the visitor
                sys.stderr.write(
                    f"[walkin] {identity} would not resume for its new owner: {type(exc).__name__}: {exc}\n"
                )
        return body

    def ended_signal_of(self, user_id: str) -> str | None:
        """The signalling path of the clone this visitor JUST LOST, or None.

        The wall above needs a machine still standing; this is the same moment
        when there is none — the reap already took it. The plane still owes the
        stranger the honest answer, the 410 `session-end` document
        `signal_route.py` builds. But the role fence runs FIRST and matches only
        `own_of`, which the reap has cleared, so a stranger was refused 401 on
        their own clone and the SPA rendered it as "Reconnecting (1/6…4/6)" —
        measured 2026-09-11 04:14:39Z on walkin-rhapsody-2. A signed-in visitor
        never saw it: `gate.allows` lets every other role through unconditionally.

        One document wide, read-only: their own just-ended clone, for
        `CLOSE_MEMORY`, matched exactly by `auth/gate.py` so the webrtc offer
        beside it stays refused. `WALKIN_CLOSED` is withheld — a class of
        visitor that keeps a surface across the operator's kill switch is what
        the switch exists to make impossible.
        """
        with self._lock:
            entry = self._closes.get(user_id)
            if not entry or len(entry) < 3 or entry[0] == CLOSE_REASON_CLOSED:
                return None
            return f"/signal/{entry[2]}.json"

    def wall_message(self, identity: str, frozen_reason: str) -> dict:
        """The §3.3 message for a clone that has stopped answering, or None.

        Two ways a clone can stop: it was reaped (the broker remembers why), or
        it is frozen behind the conversion wall (it is very much alive, and the
        reason belongs to the auth plane — which is why the caller passes it in
        rather than this package learning about budgets). Anything else with no
        time left is an ordinary session that ran out its clock, and telling
        THAT visitor about an anonymous budget would be a lie.
        """
        ended = self.session_end_for_clone(identity)
        if ended:
            return ended
        return session_end_message(frozen_reason if self.is_frozen(identity) else CLOSE_REASON_TTL)

    def retime(self, user_id: str, identity: str, ttl: float) -> int:
        """Cut this session's remaining life to `ttl` seconds. Never lengthens it.

        The anonymous budget needs it and nothing else does. A stranger's claim
        is built with the longest their visit could last — the un-touched window
        plus their minute — because at claim time their minute has not started
        (`auth/anon.py begin`). The instant they touch the guest it HAS started,
        and the session has to shrink to it: `ticket_ttl_for` caps a media
        ticket at the session's remaining seconds, so a session outliving the
        budget is a reconnect window outliving the wall, which the landing
        contract forbids in as many words.

        **It can only ever shorten**, and that is a fence rather than a detail:
        the caller is `POST /walkin/engage`, which any visitor can send as often
        as they like. A re-arm that could push `expires_at` out would be a
        browser voting itself more time.
        """
        with self._lock:
            member = self._members.get(identity)
            if not member or not member.session or member.session.user_id != user_id:
                raise BrokerError(f"{identity} is not yours")
            now = self._now()
            member.session.expires_at = min(member.session.expires_at, now + max(0.0, float(ttl)))
            return member.session.ttl_left(now)

    def ticket_ttl_for(self, identity: str, default: int) -> int:
        """How long a media-plane ticket for this clone may live.

        The rule, and it is stricter than the one it replaces: **a walk-in
        ticket never outlives the session it belongs to.** `serve_tile` re-mints
        on every signalling fetch, so a fixed five-minute ticket let a reconnect
        at T+59 buy five more minutes of connect window past a sixty-second
        budget. Capping at the session's own remaining seconds closes that, and
        a frozen session caps at zero — no reconnect, no second tab, no other
        browser.

        A clone with no session at all keeps the default: that is a warm pool
        member nobody holds, and the role fence is what stops a stranger asking
        about it in the first place.
        """
        with self._lock:
            member = self._members.get(identity)
            if member is None or member.session is None:
                return int(default)
            if identity in self.frozen:
                return 0
            return int(max(0, min(int(default), member.session.ttl_left(self._now()))))

    def next_expiry(self) -> float | None:
        """The earliest instant any live session ends, or None.

        The watchdog sleeps on this so a sixty-second budget is not enforced by
        a fifteen-second tick. Sweeps the frozen map on the way past, which is
        the only place it needs sweeping.
        """
        with self._lock:
            if self._frozen:
                self._frozen = {i: t for i, t in self._frozen.items() if i in self._members}
            ends = [m.session.expires_at for m in self._members.values() if m.session]
            return min(ends) if ends else None
