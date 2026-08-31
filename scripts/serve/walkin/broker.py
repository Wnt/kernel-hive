"""The warm pool, the sessions on it, and the watchdog that keeps both honest.

The invariant everything else serves: **a clone is never handed to a second
visitor.** There is therefore no path in this file that returns a used clone to
the pool. A session ends, the clone is destroyed, and a fresh one is built from
the golden — "reset" is a respawn, not a cleanup.

Pool members sit `-loadvm golden -S`: restored, paused, costing RAM and no CPU
(`docs/lab/OVERHEAD.md`). A claim resumes one; that is the entire difference
between a warm pool member and a live session, and it is why the pool can be
warm without the museum feeling it.

Ends, and their reason codes (ledger §3.1):

    release  the visitor left            (no code; they know)
    TTL      20 minutes                  WALKIN_TTL
    idle     3 minutes with no input     WALKIN_IDLE
    closed   access dropped to Closed    WALKIN_CLOSED

The reason is recorded per user AND per clone identity, because a dropped client
can come back asking either way: the play surface polls `/walkin/state` with its
session cookie, while a reconnect attempt asks `/signal/<clone>.json` for a
machine that no longer exists. Both roads answer the ledger §3.3 message —

    {"type": "session-end", "reason": "WALKIN_TTL"}

— rather than a bare 404, so the visitor is told their twenty minutes are up
instead of "connection lost". Lane 4 prefers this code over anything it inferred.
"""

from __future__ import annotations

import contextlib
import os
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from . import claims, reaper
from . import clone as clone_mod
from . import spec as spec_mod
from .warm import BrokerError, Member, Warming

# Server-side feature reach (serve/probes.py). Two module names for one module —
# see the identical block in auth/gate.py. A watchdog that dies stops reaping, so
# the import degrades to a no-op rather than to a traceback.
try:
    from probes import hit
except ImportError:  # pragma: no cover - import shape only
    try:
        from serve.probes import hit
    except ImportError:

        def hit(_probe: str) -> None:
            """No probes module in this deployment; the pool still runs."""


# Spans (serve/tracing.py); see the note on the same import in signal_route.py.
try:
    import tracing
except ImportError:  # pragma: no cover - import shape only
    from serve import tracing


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


class Broker(Warming):
    """One instance per serving process. Thread-safe; `tick` is the watchdog.

    **The lock discipline, which is load-bearing.** Everything a request handler
    reads — `pools`, `state`, `live_sessions`, `own_of`, `signal_entries` — takes
    `self._lock`, so nothing that takes MINUTES may hold it. Building a clone is
    a TCG restore of roughly two minutes; killing one is a handful of
    subprocesses. Both therefore happen with the lock released:

        reserve (locked)  ->  build (unlocked)   ->  publish (locked)
        retire  (locked)  ->  destroy (unlocked)

    What the lock still protects is the thing it is actually for: no two builds
    may pick the same pool index, and no clone may be handed to a second
    visitor. Indexes are RESERVED under the lock before the build starts, and
    `_build_lock` — which no read path touches — keeps the builds themselves
    one at a time. `kh-claim` arbitrates between SESSIONS; the broker is one
    session, so within it the reservation is the arbitration.
    """

    def __init__(self, registry_dir, repo_root, now=time.time, spawn: bool = True, factory=None, daemon: bool = True):
        self.registry_dir = Path(registry_dir)
        self.repo_root = Path(repo_root)
        self._now = now
        self._spawn = spawn  # False in tests: build the plan, run no processes
        self._daemon = daemon  # False when only the guest half is under test
        # The one seam in this file. Everything above the factory is pool policy
        # — who gets a machine, for how long, and what happens when they stop
        # typing — and it is testable without a hypervisor precisely because
        # making the machine is somebody else's function.
        self.factory = factory or (lambda spec, index: clone_mod.build(spec, index, self.repo_root))
        # Two locks, because they guard two things that move at wildly
        # different speeds. `_lock` guards the pool's BOOKKEEPING and is held
        # for microseconds; every request handler needs it. `_build_lock`
        # serialises the MAKING of a clone, which is a TCG restore of minutes,
        # and no read path ever touches it. Holding the first while doing the
        # second's work is what made `/walkin/state` time out at poolSize 3.
        self._lock = threading.RLock()
        self._build_lock = threading.Lock()
        self._members: dict[str, Member] = {}
        # Clones that exist but are not pool members — not yet, or not any
        # more. Both are still OURS, and the reapers must not read them as
        # leftovers: a reservation holds an index and a slot claim before its
        # directory exists, and a retiring clone still has a tap, a claim and a
        # directory for as long as `destroy` runs (outside the lock).
        self._building: dict[str, tuple] = {}  # identity -> (station, index)
        self._retiring: dict[str, object] = {}  # identity -> clone
        self._refill_wanted = False
        self._queue: list = []  # [(user_id, station, since)]
        self._closes: dict[str, tuple] = {}  # user_id -> (code, at)
        self._ended: dict[str, tuple] = {}  # clone identity -> (code, at)
        self._next_index: dict[str, int] = {}
        self.specs: dict[str, spec_mod.StationSpec] = {}
        self.access = "closed"
        # Whether the pool is supposed to be warm at all. `kill_all_clones`
        # clears it and `refill` sets it, so the watchdog cannot quietly
        # repopulate a pool an admin has just emptied — which would undo the
        # kill switch on a timer, silently, about a second later.
        self.warm = False
        self.drain = False
        self.reload_specs()
        if not os.environ.get("KH_SESSION"):
            # Said once, here, rather than discovered as a refused claim on the
            # first visitor: without it every take fails and the pool never warms.
            sys.stderr.write(
                "[walkin] KH_SESSION is unset — every slot claim will be refused and no clone can be built. "
                "The serving unit must set it (rule 7).\n"
            )
        # A restarted serving process inherits BOTH halves of its previous
        # incarnation: clone directories with live QEMUs behind them, and the
        # /run claims those clones took. Neither is ours any more — a clone is
        # never handed to a second visitor, and that includes the visitor who was
        # on it before the restart. Reap first, then hand back whatever the reap
        # did not account for, so the first refill starts from a clean range
        # rather than allocating around the wreckage.
        with contextlib.suppress(Exception):
            self.reap_orphans()
        with contextlib.suppress(Exception):
            self.release_stray_claims()

    # -- the surface lane 2 calls (contract ledger §3.1) -------------------
    #
    # Frozen names, duck-typed, bound with `AUTH.walkin.bind_broker(...)`. The
    # switch itself lives in `auth/walkin.py`: it persists the position, refuses
    # inflow FIRST and only then calls down here. So this side owns no policy
    # about who may reach the plane — it owns clones, and does exactly what it
    # is told, in the order it is told.

    def live_sessions(self) -> int:
        with self._lock:
            return self._active_count()

    def close_sessions(self, reason: str = CLOSE_REASON_CLOSED) -> int:
        """End every live session with `reason`. Leaves the warm pool alone.

        Separate from `kill_all_clones` because the teardown order matters and
        is lane 2's to sequence: tickets are revoked between these two calls, so
        a client disconnected here cannot re-handshake into a clone that is
        still standing when it is killed a moment later.
        """
        with self._lock:
            live = [m for m in self._members.values() if m.session]
            retired = [self._end(member, reason) for member in live]
        self._destroy(retired)
        return len(live)

    def kill_all_clones(self) -> None:
        """Empty the pool, and keep it empty until someone calls `refill`."""
        with self._lock:
            self.warm = False
            retired = [self._end(m, "") for m in list(self._members.values())]
        self._destroy(retired)

    def refill(self) -> None:
        """Top every enabled pool up to its size, and keep it that way.

        Returns as soon as the intent is recorded. The building is a TCG
        restore per member — minutes, at poolSize 3 — and every caller of this
        is an admin request or the watchdog, neither of which may sit on it.
        """
        with self._lock:
            self.warm = True
        self._kick_refill()

    def set_drain(self, value: bool) -> None:
        """The softer sibling of the kill switch: refuse new claims, let the
        sessions in flight finish. Tears nothing down."""
        with self._lock:
            self.drain = bool(value)

    # -- configuration ---------------------------------------------------

    def reload_specs(self) -> None:
        # Read the registry first, publish second: a directory of JSON is not
        # free, and `pools()` is on the visitor's poll path.
        loaded = spec_mod.load_all(self.registry_dir) if self.registry_dir.exists() else {}
        with self._lock:
            self.specs = loaded

    def set_access(self, access: str) -> int:
        """Lane 2 moves the switch; the broker does what the position means.

        Dropping to Closed disconnects and reaps — inflow is already refused by
        the auth layer at that point, which is the order the brief insists on
        (§5.1): nothing may re-enter behind the teardown.
        """
        with self._lock:
            self.access = access
        if access == "closed":
            closed = self.close_sessions(CLOSE_REASON_CLOSED)
            self.kill_all_clones()
            return closed
        self.refill()
        return 0

    # -- the pool --------------------------------------------------------

    def pools(self) -> list:
        with self._lock:
            out = []
            for station, spec in sorted(self.specs.items()):
                if not spec.enabled:
                    continue
                mine = [m for m in self._members.values() if m.clone.spec.station == station]
                out.append({"os": station, "free": sum(1 for m in mine if not m.session), "size": spec.pool_size})
            return out

    def state(self) -> dict:
        with self._lock:
            doc = {"access": self.access, "pools": self.pools()}
            if self.access == "closed":
                doc["notice"] = "Walk-in access is currently closed."
            return doc

    # -- the lifecycle ---------------------------------------------------

    def claim(self, user_id: str, station: str) -> dict:
        """Traced wrapper around `_claim`: THE OUTCOME is the finding — got a
        machine, joined a queue, or refused — and each answers a different
        question about the pool's size. The user id is never recorded (a
        walk-in is an anonymous stranger); the clone identity is, and
        `walkin-<os>-<n>` names no one."""
        with tracing.child("walkin.claim", {"kh.station": station}) as span:
            out = self._claim(user_id, station)
            if out.get("queued"):
                span.end("ok", {"kh.walkin.outcome": "queued", "kh.walkin.queuePosition": out.get("position") or 0})
            else:
                span.end("ok", {"kh.walkin.outcome": "granted", "kh.clone": out.get("clone") or ""})
            return out

    def _claim(self, user_id: str, station: str) -> dict:
        with self._lock:
            if self.access == "closed":
                raise BrokerError("walkin_closed")
            if self.drain:
                raise BrokerError("the walk-in plane is draining for maintenance; try again shortly")
            spec = self.specs.get(station)
            if not spec or not spec.enabled:
                raise BrokerError(f"no walk-in pool for {station!r}")
            existing = self._session_of(user_id)
            if existing:
                raise BrokerError(f"you already have {existing.identity} — release it first")
            # Both exits below are the same finding — "somebody wanted a machine
            # and had to wait" — and the queue is the same machinery either way,
            # so they are one probe. A pool of three on a private museum may
            # never reach either, and that is the answer worth having.
            if self._active_count() >= ACTIVE_SESSION_CAP:
                hit("walkin.claim.queued")
                return self._enqueue(user_id, station)
            free = next((m for m in self._members.values() if m.clone.spec.station == station and not m.session), None)
            if not free:
                hit("walkin.claim.queued")
                return self._enqueue(user_id, station)
            now = self._now()
            free.session = Session(
                identity=free.identity,
                station=station,
                user_id=user_id,
                started_at=now,
                expires_at=now + TTL_SECONDS,
                last_input_at=now,
            )
            self._dequeue(user_id)
            clone, identity = free.clone, free.identity
        # Outside the lock: a resume is a wake lease plus QMP round trips plus a
        # verify, and it holds up every other visitor's `/walkin/state` if it is
        # done in here. The member is already marked as this visitor's, so
        # nobody else can be handed it while it wakes.
        if self._spawn:
            try:
                # THE SLOWEST THING THIS SERVER DOES, and the one a visitor is
                # actually staring at: a wake lease, QMP round trips and a
                # verify against a paused clone. Its own span so "the walk-in
                # felt slow" resolves to the resume or to everything else.
                with tracing.child("walkin.clone.resume", {"kh.clone": identity}):
                    clone.resume()
            except Exception as exc:
                hit("walkin.claim.resumeFailed")
                self._abandon(identity, user_id)
                raise BrokerError(f"{identity} would not resume: {exc}") from exc
        return {
            "clone": identity,
            "signalEndpoint": f"/signal/{identity}.json",
            "ttlSeconds": TTL_SECONDS,
        }

    def _abandon(self, identity: str, user_id: str) -> None:
        """A clone that was handed out and then failed to wake. It is not the
        visitor's and it is not the pool's — a used clone is never re-listed."""
        with self._lock:
            member = self._members.get(identity)
            retired = self._end(member, "") if member and member.session and member.session.user_id == user_id else None
        if retired is not None:
            self._destroy([retired])
        self._kick_refill()

    def release(self, user_id: str, identity: str, reason: str = "") -> dict:
        with self._lock:
            member = self._members.get(identity)
            if not member or not member.session or member.session.user_id != user_id:
                raise BrokerError(f"{identity} is not yours")
            retired = self._end(member, reason)
        self._destroy([retired])
        self._kick_refill()
        return {"ok": True}

    def reset(self, user_id: str, identity: str) -> dict:
        """Visitor-facing reset: discard my clone, give me a fresh one.

        Implemented as end + claim precisely because a used clone is never
        recycled — the visitor's next machine comes off the golden like anyone
        else's, which is the same guarantee the NEXT visitor gets.
        """
        with self._lock:
            member = self._members.get(identity)
            if not member or not member.session or member.session.user_id != user_id:
                raise BrokerError(f"{identity} is not yours")
            station = member.clone.spec.station
            retired = self._end(member, "")
        self._destroy([retired])
        self._kick_refill()
        return self.claim(user_id, station)

    def note_input(self, identity: str) -> None:
        """Called by the input path; resets the idle clock. Cheap on purpose."""
        with self._lock:
            member = self._members.get(identity)
            if member and member.session:
                member.session.last_input_at = self._now()

    def extend(self, user_id: str, identity: str) -> int:
        """+10 minutes, but only while nobody is waiting (brief §4)."""
        with self._lock:
            member = self._members.get(identity)
            if not member or not member.session or member.session.user_id != user_id:
                raise BrokerError(f"{identity} is not yours")
            if self._queue:
                return member.session.ttl_left(self._now())
            member.session.expires_at += EXTENSION_SECONDS
            return member.session.ttl_left(self._now())

    def close_reason(self, user_id: str) -> str:
        with self._lock:
            entry = self._closes.get(user_id)
            return entry[0] if entry else ""

    def session_end(self, user_id: str) -> dict | None:
        """The §3.3 message for this visitor's last session, or None."""
        reason = self.close_reason(user_id)
        return session_end_message(reason) if reason else None

    def own_of(self, user_id: str) -> dict | None:
        """The clone this visitor holds — `station`, `clone`, `signalEndpoint`.

        The serving plane asks this on every gated request a walk-in makes. A
        walk-in's ONE interactive surface is their own clone's signaling
        document (`auth/gate.py::walkin_allows`), and the fence can only allow
        it if it is told which one that is; the same shape is what the manifest
        projection marks playable. Read-only, so it is safe on the hot path.
        """
        with self._lock:
            session = self._session_of(user_id)
            if not session:
                return None
            return {
                "station": session.station,
                "clone": session.identity,
                "signalEndpoint": f"/signal/{session.identity}.json",
                "transport": "streamhost",
            }

    def session_end_for_clone(self, identity: str) -> dict | None:
        """The §3.3 message for a clone that has been reaped, or None.

        The seam behind `/signal/<clone>.json`: a client that lost its transport
        retries the signaling document first, and a 404 there is exactly the
        "connection lost" lie this code exists to prevent.
        """
        with self._lock:
            entry = self._ended.get(identity)
            return session_end_message(entry[0]) if entry else None

    def close_all(self, reason: str = CLOSE_REASON_CLOSED) -> int:
        """`close_sessions` + `kill_all_clones` in one call, for the smoke check
        and the CLI. Lane 2 uses the two halves, in that order, with the ticket
        revocation between them."""
        closed = self.close_sessions(reason)
        self.kill_all_clones()
        return closed

    # -- the watchdog ----------------------------------------------------

    def tick(self) -> dict:
        """Expire, reap, refill. Idempotent; safe to call on a short timer."""
        now = self._now()
        ended, died, retired = [], [], []
        with self._lock:
            for member in list(self._members.values()):
                session = member.session
                if session and now >= session.expires_at:
                    hit("walkin.reap.ttl")
                    ended.append((member.identity, CLOSE_REASON_TTL))
                    retired.append(self._end(member, CLOSE_REASON_TTL))
                elif session and now - session.last_input_at >= IDLE_SECONDS:
                    # The idle window is three minutes and the TTL is twenty, so
                    # the idle reap should be the COMMON one; if it is not, the
                    # 3-minute window is not doing what it was added to do.
                    hit("walkin.reap.idle")
                    ended.append((member.identity, CLOSE_REASON_IDLE))
                    retired.append(self._end(member, CLOSE_REASON_IDLE))
                elif not member.clone.alive():
                    hit("walkin.reap.died")
                    # A pool member whose QEMU died is not a pool member. It is a
                    # directory and a claim, and both have to go back.
                    died.append(member.identity)
                    retired.append(self._end(member, ""))
            self._closes = {u: v for u, v in self._closes.items() if now - v[1] < CLOSE_MEMORY}
            self._ended = {c: v for c, v in self._ended.items() if now - v[1] < CLOSE_MEMORY}
        # A reap has NO REQUEST BEHIND IT (own timer thread), so it is a root
        # of its own — and only when something ENDED: a tick that found nothing
        # is not a journey, and a span every 15 s forever would be the loudest
        # thing in the store. The reasons go on the span because the probe
        # counters say how often and cannot say how long the destroy took.
        span = tracing.NOOP
        if ended or died:
            span = tracing.start_trace(
                "walkin.reap",
                {
                    "kh.walkin.ended": len(ended),
                    "kh.walkin.died": len(died),
                    "kh.walkin.reasons": ",".join(sorted({r for _, r in ended if r})) or "none",
                },
            )
        with span:
            self._destroy(retired)
            orphans = self.reap_orphans()
            taps = self.reap_orphan_taps()
            cells = self.reap_orphan_cells()
            # A claim registry that is unreachable must not stop the watchdog
            # doing the two things that actually keep the pool honest.
            try:
                strays = self.release_stray_claims()
            except Exception as exc:
                sys.stderr.write(f"[walkin] could not check for stray claims: {exc}\n")
                strays = []
            built = self._refill()
        return {"ended": ended, "died": died, "orphans": orphans, "taps": taps, "cells": cells,
                "strays": strays, "built": built}  # fmt: skip

    def reap_orphans(self) -> list:
        """Clone roots on disk that this broker does not own — kill and discard."""
        return reaper.reap_orphan_dirs(self._known_identities())

    def reap_orphan_taps(self) -> list:
        """Walk-in taps on the box that no clone stands behind."""
        with self._lock:
            known = {m.clone.plan.tap for m in self._members.values()}
            known |= {c.plan.tap for c in self._retiring.values()}
        return reaper.reap_orphan_taps(known)

    def reap_orphan_cells(self) -> list:
        """Walk-in L2 cells on the box that no clone stands behind."""
        with self._lock:
            known = {m.clone.plan.slot for m in self._members.values()}
            known |= {c.plan.slot for c in self._retiring.values()}
        return reaper.reap_orphan_cells(known)

    def release_stray_claims(self) -> list:
        """Give back slot and port claims that no clone stands behind."""
        return reaper.release_stray_claims(self._known_identities())

    def signal_entries(self) -> dict:
        """`{identity: {udpPort, hashFile}}` — the pool's rows for the signaling
        config, in tiles.json's own shape, so `/signal/<clone>.json` can answer
        for a clone exactly as it does for a station."""
        with self._lock:
            return {
                m.identity: {
                    "udpPort": m.clone.plan.udp_port,
                    "hashFile": str(m.clone.plan.root / "cert_hash_b64.txt"),
                }
                for m in self._members.values()
            }

    # -- internals -------------------------------------------------------

    def _known_identities(self) -> set:
        """Every clone this broker answers for — members, reservations AND the
        ones it is currently destroying.

        A reservation claims its slot before it has a directory, and a retiring
        clone keeps its directory until `destroy` finishes; both now happen
        outside the lock and therefore alongside a tick. A reaper told only
        about `_members` would release the slot out from under a clone that is
        mid-restore — which is precisely the failure the sweeps exist to fix,
        pointed the wrong way.
        """
        with self._lock:
            return set(self._members) | set(self._building) | set(self._retiring)

    def _active_count(self) -> int:
        return sum(1 for m in self._members.values() if m.session)

    def _session_of(self, user_id: str) -> Session | None:
        for member in self._members.values():
            if member.session and member.session.user_id == user_id:
                return member.session
        return None

    def _enqueue(self, user_id: str, station: str) -> dict:
        if not any(entry[0] == user_id for entry in self._queue):
            self._queue.append((user_id, station, self._now()))
        position = [entry[0] for entry in self._queue].index(user_id) + 1
        return {"queued": True, "position": position}

    def _dequeue(self, user_id: str) -> None:
        self._queue = [entry for entry in self._queue if entry[0] != user_id]

    def _end(self, member: Member, reason: str):
        """Take a member out of the pool and hand its clone back to be destroyed.

        **Called with the lock held; returns without destroying anything.** The
        destruction is a kill, a tap down, a cell down and an `rm -rf` — seconds
        of subprocess work each, and every request handler needs this lock. The
        caller passes what it collects to `_destroy` once it is out.
        """
        session = member.session
        if session and reason:
            self._closes[session.user_id] = (reason, self._now())
            self._ended[member.identity] = (reason, self._now())
        member.session = None
        self._members.pop(member.identity, None)
        self._retiring[member.identity] = member.clone
        return member.clone


def slot_claims_held() -> list:
    """Every walk-in slot claim this session holds — the teardown check."""
    import subprocess

    proc = subprocess.run([claims.kh_claim_bin(), "ls", "--mine"], capture_output=True, text=True, check=False)
    return [ln for ln in proc.stdout.splitlines() if claims.SLOT_CLASS in ln or "port/54" in ln]
