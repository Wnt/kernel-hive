"""Freezing a session in place, and handing the same machine to an account.

The pool's founding invariant is that **a clone is never handed to a second
visitor** — a session ends, the machine is destroyed, the next visitor's comes
off the golden. This module does not weaken that. It adds the one case where a
machine outlives the session that was on it *for the same human*: the anonymous
stranger who has just run out of their five minutes and is being asked to make
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
    without a restamp at freeze time the ordinary 180-second idle window would
    still be counting from whenever the visitor last engaged — which, once a
    budget can run longer than three minutes, is well before the wall itself
    (`retime`, below, exempts the same session from that window the instant it
    starts spending; freezing is the second half, for the moment it stops).
    Freezing therefore restamps `last_input_at`, which is the only honest thing
    to do with it: the visitor is not idle, they are stopped.

SWITCHING IS THE SECOND CASE, and it is the same mechanism (2026-09-15). The
landing page offers three machines and a visitor tries all three; until now
leaving one DESTROYED it, so coming back to Win 3.11 after a look at OS/2 got a
fresh boot off the golden and the desktop they had arranged was gone. Now the
machine they leave is frozen and reserved for them for `HOLD_SECONDS`, and
coming back inside that window THAWS the very same clone — same qcow2, same
vmstate, same screen, same session, its TTL never lengthened by the round trip.

That turns "one clone per account" into "one clone RUNNING per account, plus up
to `MAX_HOLDS_PER_VISITOR` stopped ones", and the founding invariant is
untouched: every held clone still has a `Session` on it, so it is not free, it
is in no other visitor's claim, it counts against the pool's free number and
against `ACTIVE_SESSION_CAP`. **A clone is still never handed to a second
visitor.** What changed is only how long ONE visitor's machine outlives their
attention.

Three consequences that are easy to get wrong, and are tested for:

  * **A visitor has several sessions now, so "theirs" is ambiguous.** `own_of`,
    `freeze` and `reassign` each needed a different answer: the machine they
    are DRIVING (`_active_of` — the one session not in `frozen`), versus the
    machine they were LAST ON (`_last_used_of` — the active one, else the most
    recently frozen). The conversion wall wants the second, which is item 2 of
    the operator's ask: register inside the window and you resume the machine
    you were on when you hit the wall, not whichever hold sorts first.
  * **A hold lapsing must not tell the visitor their SESSION ended.** The
    reaper ends an expired session with `WALKIN_TTL`, and `_end` records that
    against the USER — so a Win 3.11 hold quietly expiring while its visitor
    drives OS/2 would have posted "your session ended" over a machine that is
    running fine. A hold that is not their last-used machine is therefore ended
    silently (`Broker.tick`); there is nothing on screen for it to be about.
  * **The freeze's QMP round trip must not happen under the broker lock.** The
    pause is seconds of hypervisor work and every request handler needs that
    lock, so the locked half (`_freeze_locked`) and the unlocked half
    (`_settle_freeze`) are separate — `freeze()` is just the two in order, and
    `Broker._claim` calls them around its own locked section.
"""

from __future__ import annotations

import sys

from .session import (
    CLOSE_REASON_CLOSED,
    CLOSE_REASON_TTL,
    HOLD_SECONDS,
    MAX_HOLDS_PER_VISITOR,
    TTL_SECONDS,
    claim_body,
    session_end_message,
)
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

    #: Bumped on every freeze, so "which machine did they leave last" has an
    #: answer a clock tie cannot spoil. See `Session.used_seq`.
    _use_seq: int = 0

    def is_frozen(self, identity: str) -> bool:
        """Whether this clone is stopped behind a wall. Stale entries — a clone
        already destroyed — answer False and are swept by `next_expiry`."""
        with self._lock:
            return identity in self.frozen and identity in self._members

    # -- which of this visitor's machines ----------------------------------
    #
    #  A visitor used to have exactly one session, so `_session_of` was the
    #  whole question. With holds they can have several, and the three callers
    #  that used to share that one answer each want a DIFFERENT one. Getting
    #  this wrong is silent: it hands back the wrong machine rather than
    #  failing, which is why they are three named methods and not a flag.

    def _sessions_of(self, user_id: str) -> list:
        return [m.session for m in self._members.values() if m.session and m.session.user_id == user_id]

    def _active_of(self, user_id: str):
        """The machine this visitor is DRIVING — the one session not frozen.

        At most one by construction: `Broker._claim` freezes the outgoing
        machine in the same locked section that takes the incoming one.
        """
        for session in self._sessions_of(user_id):
            if session.identity not in self.frozen:
                return session
        return None

    def _last_used_of(self, user_id: str):
        """The machine this visitor was LAST ON, frozen or not.

        The active one if they are driving something; otherwise the hold they
        left most recently. This is the conversion wall's answer — a visitor
        who registers gets back the screen they were looking at when the wall
        went up, not whichever of their holds happens to sort first — and it is
        also what `own_of` owes the gate, so a frozen visitor is still
        recognised as the holder of their own signalling document.
        """
        sessions = self._sessions_of(user_id)
        if not sessions:
            return None
        return max(sessions, key=lambda s: (s.identity not in self.frozen, s.used_seq))

    def holds_of(self, user_id: str) -> list:
        """This visitor's frozen machines, for `GET /walkin/state` (`holds`).

        The UI's whole basis for saying "yours, waiting, 4:01 left" instead of
        drawing a held machine identically to a free one. Lapsed entries are
        omitted rather than reported as 0: the reaper is what actually destroys
        them and it runs on a tick, so between the deadline and the reap the
        honest answer to "is this still yours" is no.
        """
        with self._lock:
            now = self._now()
            held = [
                {"os": s.station, "clone": s.identity, "secondsLeft": s.ttl_left(now)}
                for s in self._sessions_of(user_id)
                if s.identity in self.frozen and s.ttl_left(now) > 0
            ]
        return sorted(held, key=lambda entry: entry["os"])

    # -- freezing, in two halves -------------------------------------------

    def freeze(self, user_id: str, hold_secs: float = HOLD_SECONDS) -> str:
        """Stop this visitor's machine and reserve it for `hold_secs`.

        Returns the clone identity, or "" if they held nothing. The clone stays
        a member with its session attached, which is what keeps it out of every
        free count and out of every other visitor's claim.
        """
        with self._lock:
            plan = self._freeze_locked(self._active_of(user_id), hold_secs)
        return self._settle_freeze(user_id, plan)

    def _leave_locked(self, session):
        """The machine this visitor is walking away from. Lock held; returns
        `(freeze plan, clones to destroy)`.

        **A session whose clock already ran out is retired, not frozen**, and
        that distinction is the whole difference between a hold and an exploit:
        freezing an expired session would hand it `HOLD_SECONDS` of fresh life,
        so a visitor whose twenty minutes (or whose anonymous budget) were spent
        could keep resurrecting the same machine by pressing the switcher. It
        also broke the ledger's oldest promise out loud — `test_broker
        .test_a_reload_after_the_clock_ran_out_gets_a_fresh_clone` went red the
        first time this method did not exist. Ended with no reason, exactly as
        the pre-hold code did: the reaper's own `WALKIN_TTL` is what tells the
        visitor, and it has already been recorded or is about to be.
        """
        if session is None:
            return None, []
        if session.ttl_left(self._now()) > 0:
            return self._freeze_locked(session), []
        member = self._members.get(session.identity)
        return None, ([self._end(member, "")] if member else [])

    def _freeze_locked(self, session, hold_secs: float = HOLD_SECONDS):
        """The bookkeeping half. **Called with the lock held, and it is the
        whole reason the ticket door shuts before anything can fail:**
        `ticket_ttl_for` answers 0 from the instant `frozen` is written, so a
        pause that then fails cannot leave a running machine behind a wall.

        Returns `(identity, clone)` for `_settle_freeze`, or None.
        """
        if session is None:
            return None
        member = self._members.get(session.identity)
        if member is None:
            return None
        now = self._now()
        self.frozen[session.identity] = now
        session.expires_at = now + float(hold_secs)
        # See the module docstring: the idle window is a second TTL counted
        # from the claim, and a hold must not be reaped by it.
        session.last_input_at = now
        # The instant it stopped being the machine in front of them — the
        # ordering `_last_used_of` and the ceiling's eviction both read, with
        # `used_seq` as the tiebreak a shared clock reading would otherwise lose.
        session.used_at = now
        self._use_seq += 1
        session.used_seq = self._use_seq
        return session.identity, member.clone

    def _settle_freeze(self, user_id: str, plan) -> str:
        """The hypervisor half — a QMP round trip, and therefore NEVER under
        the broker lock (`Broker._claim` holds it while a visitor's switch is
        being booked, and every other request handler needs it)."""
        if plan is None:
            return ""
        identity, clone = plan
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

    # -- coming back, and the ceiling --------------------------------------

    def _thaw_locked(self, user_id: str, station: str, ttl: float | None):
        """This visitor's own held machine for `station`, woken. Lock held.

        Returns the `Member` — its existing `Session` restamped, its entry gone
        from `frozen` — or None if they hold nothing for this station. The
        caller resumes the clone outside the lock, on exactly the same path a
        fresh claim takes, which is what makes "resume" and "claim" one code
        path with one failure handler instead of two.

        The clone, the qcow2 and the vmstate are untouched: this is the same
        machine, still stopped exactly where the visitor left it. The TTL is a
        FRESH one rather than what was left on the hold, because the hold's
        clock was measuring how long the machine waits, not how long they may
        drive it — and for an anonymous visitor `ttl` is their remaining
        budget, which is the bound that actually matters.
        """
        now = self._now()
        for session in self._sessions_of(user_id):
            if session.identity not in self.frozen or session.station != station:
                continue
            member = self._members.get(session.identity)
            if member is None or session.ttl_left(now) <= 0:
                continue
            self.frozen.pop(session.identity, None)
            session.expires_at = now + (TTL_SECONDS if ttl is None else max(0.0, float(ttl)))
            session.last_input_at = now
            session.used_at = now
            return member
        return None

    def _evict_locked(self, user_id: str) -> list:
        """Retire this visitor's holds over the ceiling. Lock held; returns the
        clones for `_destroy`.

        Oldest-first by `used_at` — the machine they walked away from longest
        ago is the one they are least likely to be coming back to. Ended with
        NO reason, because there is nothing on this visitor's screen for a
        `session-end` to be about; see the module docstring.
        """
        held = sorted(
            (s for s in self._sessions_of(user_id) if s.identity in self.frozen),
            key=lambda s: s.used_seq,
        )
        retired = []
        for session in held[: max(0, len(held) - MAX_HOLDS_PER_VISITOR)]:
            member = self._members.get(session.identity)
            if member is None:
                continue
            self.frozen.pop(session.identity, None)
            retired.append(self._end(member, ""))
        return retired

    def end_reason_for(self, session, reason: str) -> str:
        """The reason `Broker.tick` should end this expired session with.

        A hold lapsing in the background is NOT a session ending. `_end`
        records the reason against the USER, and `GET /walkin/state` hands it
        straight to the SPA as `sessionEnd`, so a Win 3.11 hold quietly
        expiring while its visitor drives OS/2 used to post "your session
        ended" over a machine that was running perfectly well. Only the
        visitor's last-used machine has a screen for that message to be about.
        """
        with self._lock:
            if session.identity not in self.frozen:
                return reason
            last = self._last_used_of(session.user_id)
            return reason if last is not None and last.identity == session.identity else ""

    def reassign(self, from_user: str, to_user: str, ttl: float) -> dict | None:
        """Hand a frozen machine to the account its visitor just registered.

        The clone does not change; only whose it is, and for how long. That is
        the entire point of the hold — the work on the screen is the reason the
        passkey was worth making.

        **`_last_used_of`, not "their session"**, because a visitor arrives at
        the wall with up to `MAX_HOLDS_PER_VISITOR` other machines frozen
        behind them. The one that is owed back is the one they were ON when the
        wall went up — item 2 of the ask, and the only one they can see behind
        the dialog. Their OTHER holds are released here rather than left to
        lapse: the visitor is now an account driving one machine, and a hold
        nobody is coming back to is a slot, a port, a tap and a core the pool
        should have back this instant instead of up to five minutes from now.
        """
        with self._lock:
            session = self._last_used_of(from_user)
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
            session.used_at = now
            was_frozen = self.frozen.pop(identity, None) is not None
            self._closes.pop(from_user, None)
            body = claim_body(session, now, resumed=True)
            clone = member.clone
            abandoned = self._release_holds_locked(from_user)
        self._destroy(abandoned)
        if abandoned:
            self._kick_refill()
        if was_frozen:
            try:
                clone.resume()
            except Exception as exc:  # noqa: BLE001 — reported, never a 500 for the visitor
                sys.stderr.write(
                    f"[walkin] {identity} would not resume for its new owner: {type(exc).__name__}: {exc}\n"
                )
        return body

    def _release_holds_locked(self, user_id: str) -> list:
        """Every remaining frozen machine of `user_id`, retired. Lock held."""
        retired = []
        for session in self._sessions_of(user_id):
            if session.identity not in self.frozen:
                continue
            member = self._members.get(session.identity)
            if member is None:
                continue
            self.frozen.pop(session.identity, None)
            retired.append(self._end(member, ""))
        return retired

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

        **It also takes this session out of the ordinary idle reap**
        (`session.idle_exempt`, `Broker.tick`). `note_input` — the only thing
        that keeps the idle window's clock current — has exactly one caller,
        this session's own `POST /walkin/engage`, and that fires once per clone
        (`landing/useHeroSession.ts noteInput`). A budget under three minutes
        never noticed, because its own deadline always arrived first; one over
        three minutes would otherwise be cut short by a window nothing is
        refreshing, while the visitor is still driving. `expires_at` — set
        above, never lengthened — remains the backstop regardless.
        """
        with self._lock:
            member = self._members.get(identity)
            if not member or not member.session or member.session.user_id != user_id:
                raise BrokerError(f"{identity} is not yours")
            now = self._now()
            member.session.expires_at = min(member.session.expires_at, now + max(0.0, float(ttl)))
            member.session.idle_exempt = True
            return member.session.ttl_left(now)

    def ticket_ttl_for(self, identity: str, default: int) -> int:
        """How long a media-plane ticket for this clone may live.

        The rule, and it is stricter than the one it replaces: **a walk-in
        ticket never outlives the session it belongs to.** `serve_tile` re-mints
        on every signalling fetch, so a fixed five-minute ticket let a reconnect
        made just before the budget ran out buy a fresh five-minute connect
        window on the far side of it — most of a visit stolen back from the
        wall. Capping at the session's own remaining seconds closes that, and
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

        The watchdog sleeps on this so the anonymous budget is not enforced by
        a fifteen-second tick. Sweeps the frozen map on the way past, which is
        the only place it needs sweeping.
        """
        with self._lock:
            if self._frozen:
                self._frozen = {i: t for i, t in self._frozen.items() if i in self._members}
            ends = [m.session.expires_at for m in self._members.values() if m.session]
            return min(ends) if ends else None
