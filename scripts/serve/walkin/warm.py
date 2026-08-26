"""Filling the pool, and emptying it, without holding the pool's lock.

Everything in `broker.py` that a request handler reads — `pools`, `state`,
`own_of`, `live_sessions` — takes the broker's one lock. So nothing that takes
MINUTES may hold it, and both halves of a pool member's life are minutes:

* **Building** one is a TCG restore of the golden. Measured on the live plane at
  poolSize 3, 2026-08-26: about two minutes ten seconds per clone, nine clones,
  and `refill()` did all nine serially under the lock. `/walkin/state` — which a
  visitor's landing page polls every 15 s to say "1 of 3 free" — timed out for
  the whole twenty minutes after every restart, and again after every reap.
* **Destroying** one is a kill through `clone-guard`, a tap down, a cell down
  and an `rm -rf`: seconds of subprocesses, on the same lock, per member.

So this half does the work unlocked and takes the lock only to mutate:

    reserve (locked)  ->  build (unlocked)    ->  publish (locked)
    retire  (locked)  ->  destroy (unlocked)

What the lock still protects is what it is actually for. Two builds must never
pick the same pool index — the index names the tap, and a collision is an
`ip link add` failure that repeats every tick — so the index is RESERVED under
the lock before the build begins, and a reservation counts toward the pool's
size exactly as a member does. `_build_lock`, which no read path touches, keeps
the builds themselves one at a time. `kh-claim` arbitrates between SESSIONS
(`claims.py`) and the broker is ONE session, so within it the reservation is
the arbitration.

A mixin rather than a module of functions because every attribute it touches is
the broker's own: `Broker` is the policy — who gets a machine, and for how long
— and this is the machinery underneath it.
"""

from __future__ import annotations

import contextlib
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from . import clone as clone_mod
from . import naming
from . import spec as spec_mod

if TYPE_CHECKING:  # the session is the POLICY half's; a member merely carries one
    from .broker import Session


class BrokerError(RuntimeError):
    """A claim, release or reset the broker refuses."""


@dataclass
class Member:
    """A pool member: a built clone plus whether somebody has it."""

    clone: clone_mod.Clone
    session: Session | None = None
    born_at: float = field(default_factory=time.time)

    @property
    def identity(self) -> str:
        return self.clone.identity


class Warming:
    """The pool-filling half of `Broker`; never instantiated on its own."""

    def _next_member_index(self, station: str) -> int:
        """A pool index that has not been used recently, not just one that is free.

        Identities cycle 1..99 rather than always reclaiming the lowest gap, so
        `walkin-os2warp-1` does not mean three different machines in one
        afternoon of telemetry — and so a client holding a stale endpoint for a
        clone that was reaped gets a 404 instead of somebody else's session. The
        cycle is bounded because the index also builds the tap name, which the
        kernel caps at 15 characters.
        """
        used = {m.clone.plan.index for m in self._members.values() if m.clone.spec.station == station}
        # A reservation and a retiring clone hold an index just as hard as a
        # member does: the first is about to create `wi-<station>-<index>`, the
        # second has not deleted it yet. Handing either index out again is an
        # `ip link add` collision, and then a build that re-fails every tick.
        used |= {i for (st, i) in self._building.values() if st == station}
        used |= {c.plan.index for c in self._retiring.values() if c.spec.station == station}
        last = self._next_index.get(station, 0)
        for step in range(1, 100):
            index = (last + step - 1) % 99 + 1
            if index not in used:
                self._next_index[station] = index
                return index
        raise BrokerError(f"{station}: no free pool index — 99 members is not a pool, it is a leak")

    def _build(self, spec: spec_mod.StationSpec, index: int) -> Member:
        """Make one clone. **Called with no lock held** — this is the minutes.

        The index is reserved by the caller before we get here, so nothing else
        can pick it while a TCG restore runs.
        """
        built = self.factory(spec, index)
        try:
            return self._bring_up(built)
        except Exception:
            # A clone that failed between `spawn` and `prime` is a directory, a
            # tap, a cell and two claims that nothing records. Give them back
            # here rather than leaving them for the reaper: until they go, the
            # index and slot they hold refuse the next attempt at this member.
            with contextlib.suppress(Exception):
                built.destroy()
            raise

    def _bring_up(self, built) -> Member:
        if self._spawn:
            built.spawn()
            status = built.wait_ready()
            if status not in ("paused", "prelaunch", "inmigrate"):
                # A pool member that is already RUNNING has burned CPU since it
                # started and, worse, has been executing guest code nobody is
                # watching. Loud, not "probably fine".
                raise BrokerError(f"{built.identity} came up {status!r}, expected paused (-loadvm golden -S)")
            # Ledger §6: repair the golden's stale ARP entry for the gateway
            # while the member is still PAUSED and unclaimed. Doing it here,
            # rather than on claim, is why it costs the visitor nothing — and
            # why a warm pool is worth having beyond the resume latency.
            if not built.prime_network():
                sys.stderr.write(
                    f"[walkin] {built.identity}: network not primed — the visitor's first page load "
                    "will fail until the gateway ARPs it (ledger §6)\n"
                )
            if self._daemon:
                clone_mod.spawn_daemon(built)
        return Member(clone=built, born_at=self._now())

    def _next_job(self, blocked: set) -> tuple | None:
        """Under the lock, briefly: the next member to build, index reserved.

        The reservation is the whole trick. Two builds must never pick the same
        index, and the deficit has to count what is already in flight or the
        watchdog orders a second copy of the clone it is currently restoring —
        so the decision stays inside the lock while the work leaves it.
        """
        with self._lock:
            if not self.warm or self.access == "closed":
                return None
            for station, spec in sorted(self.specs.items()):
                if not spec.enabled or station in blocked:
                    continue
                have = sum(1 for m in self._members.values() if m.clone.spec.station == station)
                have += sum(1 for (st, _) in self._building.values() if st == station)
                if have >= spec.pool_size:
                    continue
                index = self._next_member_index(station)
                self._building[naming.identity(station, index)] = (station, index)
                return spec, index
        return None

    def _refill(self) -> list:
        """`refill`, but returning what it built — the watchdog reports it.

        **No lock is held while a clone is built.** `_lock` is taken twice per
        member — once to reserve an index, once to publish the finished member —
        and for nothing else, because a member is roughly two minutes of TCG
        restore and `pools()`, `own_of()` and `live_sessions()` are on the
        visitor's polling path. Nine of those under the lock is the landing page
        answering "Checking what is free…" for twenty minutes.

        Concurrency is `_build_lock`, taken WITHOUT blocking: a second caller
        does not queue behind minutes of restore, it leaves a note and the
        builder does another pass. So a release still tops the pool up promptly
        without the visitor's request waiting for the replacement.
        """
        made = []
        if not self._build_lock.acquire(blocking=False):
            with self._lock:
                self._refill_wanted = True
            return made
        blocked: set = set()
        try:
            while True:
                with self._lock:
                    self._refill_wanted = False
                job = self._next_job(blocked)
                if job is None:
                    with self._lock:
                        if not self._refill_wanted:
                            return made
                    continue
                spec, index = job
                built = self._build_one(spec, index)
                if built is None:
                    # One station's builds are failing. Say so and move on:
                    # the other pools must still fill, and the next tick retries.
                    blocked.add(spec.station)
                    continue
                made.append(built)
        finally:
            self._build_lock.release()

    def _build_one(self, spec: spec_mod.StationSpec, index: int) -> str | None:
        """Build the reserved member and publish it, or report why not."""
        ident = naming.identity(spec.station, index)
        try:
            member = self._build(spec, index)
        except Exception as exc:  # noqa: BLE001 — one bad pool must not stop the rest
            with self._lock:
                self._building.pop(ident, None)
            sys.stderr.write(f"[walkin] {ident} did not build ({type(exc).__name__}: {exc})\n")
            return None
        with self._lock:
            self._building.pop(ident, None)
            keep = self.warm and self.access != "closed"
            if keep:
                self._members[member.identity] = member
            else:
                self._retiring[member.identity] = member.clone
        if not keep:
            # The switch moved while this one was restoring. It was never in the
            # pool and it is never handed out; it is destroyed.
            self._destroy([member.clone])
            return None
        return member.identity

    def _kick_refill(self) -> None:
        """Ask for a top-up WITHOUT waiting for it.

        A visitor who presses Release must not wait for the replacement clone,
        and neither must an admin who reopens the switch: the respawn is minutes.
        With `spawn=False` there is no hypervisor and building is free, so it
        stays inline — which is also what makes the pool observable synchronously
        in tests and in the planner.
        """
        if not self._spawn:
            self._refill()
            return
        threading.Thread(target=self._refill_quietly, daemon=True, name="walkin-refill").start()

    def _refill_quietly(self) -> None:
        try:
            self._refill()
        except Exception as exc:  # noqa: BLE001 — a refill thread that dies takes nothing with it
            sys.stderr.write(f"[walkin] refill: {type(exc).__name__}: {exc}\n")

    def _destroy(self, clones) -> None:
        """Destroy retired clones, outside the lock, tolerating failure.

        A clone that will not die is the watchdog's problem, not the caller's:
        the session is over either way, and `reap_orphans` comes back for the
        remains — which is also why it stops being `_retiring` regardless.
        """
        for clone in clones:
            try:
                clone.destroy()
            except Exception as exc:  # noqa: BLE001 — reported, never raised at a visitor
                sys.stderr.write(f"[walkin] {clone.identity} would not go down: {type(exc).__name__}: {exc}\n")
            finally:
                with self._lock:
                    self._retiring.pop(clone.identity, None)
