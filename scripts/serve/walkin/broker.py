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
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import claims, naming
from . import clone as clone_mod
from . import spec as spec_mod

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


class BrokerError(RuntimeError):
    """A claim, release or reset the broker refuses."""


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


@dataclass
class Member:
    """A pool member: a built clone plus whether somebody has it."""

    clone: clone_mod.Clone
    session: Session | None = None
    born_at: float = field(default_factory=time.time)

    @property
    def identity(self) -> str:
        return self.clone.identity


class Broker:
    """One instance per serving process. Thread-safe; `tick` is the watchdog."""

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
        self._lock = threading.RLock()
        self._members: dict[str, Member] = {}
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
            for member in live:
                self._end(member, reason)
            return len(live)

    def kill_all_clones(self) -> None:
        """Empty the pool, and keep it empty until someone calls `refill`."""
        with self._lock:
            self.warm = False
            for member in list(self._members.values()):
                self._end(member, "")

    def refill(self) -> None:
        """Top every enabled pool up to its size, and keep it that way."""
        with self._lock:
            self.warm = True
        self._refill()

    def set_drain(self, value: bool) -> None:
        """The softer sibling of the kill switch: refuse new claims, let the
        sessions in flight finish. Tears nothing down."""
        with self._lock:
            self.drain = bool(value)

    # -- configuration ---------------------------------------------------

    def reload_specs(self) -> None:
        with self._lock:
            self.specs = spec_mod.load_all(self.registry_dir) if self.registry_dir.exists() else {}

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
        last = self._next_index.get(station, 0)
        for step in range(1, 100):
            index = (last + step - 1) % 99 + 1
            if index not in used:
                self._next_index[station] = index
                return index
        raise BrokerError(f"{station}: no free pool index — 99 members is not a pool, it is a leak")

    def _build(self, spec: spec_mod.StationSpec) -> Member:
        index = self._next_member_index(spec.station)
        built = self.factory(spec, index)
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

    def _refill(self) -> list:
        """`refill`, but returning what it built — the watchdog reports it."""
        made = []
        with self._lock:
            if not self.warm or self.access == "closed":
                return made
            for station, spec in sorted(self.specs.items()):
                if not spec.enabled:
                    continue
                have = sum(1 for m in self._members.values() if m.clone.spec.station == station)
                for _ in range(max(0, spec.pool_size - have)):
                    member = self._build(spec)
                    self._members[member.identity] = member
                    made.append(member.identity)
        return made

    # -- the lifecycle ---------------------------------------------------

    def claim(self, user_id: str, station: str) -> dict:
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
            if self._active_count() >= ACTIVE_SESSION_CAP:
                return self._enqueue(user_id, station)
            free = next((m for m in self._members.values() if m.clone.spec.station == station and not m.session), None)
            if not free:
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
            if self._spawn:
                free.clone.resume()
            return {
                "clone": free.identity,
                "signalEndpoint": f"/signal/{free.identity}.json",
                "ttlSeconds": TTL_SECONDS,
            }

    def release(self, user_id: str, identity: str, reason: str = "") -> dict:
        with self._lock:
            member = self._members.get(identity)
            if not member or not member.session or member.session.user_id != user_id:
                raise BrokerError(f"{identity} is not yours")
            self._end(member, reason)
        self._refill()
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
            self._end(member, "")
        self._refill()
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
        ended, died = [], []
        with self._lock:
            for member in list(self._members.values()):
                session = member.session
                if session and now >= session.expires_at:
                    ended.append((member.identity, CLOSE_REASON_TTL))
                    self._end(member, CLOSE_REASON_TTL)
                elif session and now - session.last_input_at >= IDLE_SECONDS:
                    ended.append((member.identity, CLOSE_REASON_IDLE))
                    self._end(member, CLOSE_REASON_IDLE)
                elif not member.clone.alive():
                    # A pool member whose QEMU died is not a pool member. It is a
                    # directory and a claim, and both have to go back.
                    died.append(member.identity)
                    self._end(member, "")
            self._closes = {u: v for u, v in self._closes.items() if now - v[1] < CLOSE_MEMORY}
            self._ended = {c: v for c, v in self._ended.items() if now - v[1] < CLOSE_MEMORY}
        orphans = self.reap_orphans()
        built = self._refill()
        return {"ended": ended, "died": died, "orphans": orphans, "built": built}

    def reap_orphans(self) -> list:
        """Clone roots on disk that this broker does not own — kill and discard.

        These are what a crashed or restarted serving process leaves behind. The
        pool cannot refill past its ceiling while their slots are still claimed,
        so an unreaped orphan is a pool that quietly shrinks.
        """
        root = naming.WALKIN_ROOT
        with self._lock:
            known = set(self._members)
        try:
            entries = sorted(root.iterdir())
        except OSError as exc:
            # Not there yet (nothing has been built), or not ours to read. Either
            # way the watchdog must keep running: a reaper that dies on a
            # permission error stops reaping the clones it CAN see.
            if root.exists():
                sys.stderr.write(f"[walkin] cannot scan {root} for orphans: {exc}\n")
            return []
        found = []
        for entry in entries:
            if not entry.is_dir() or entry.name in known or not entry.name.startswith("walkin-"):
                continue
            clone_mod.reap_orphan(entry)
            found.append(entry.name)
        return found

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

    def _end(self, member: Member, reason: str) -> None:
        session = member.session
        if session and reason:
            self._closes[session.user_id] = (reason, self._now())
            self._ended[member.identity] = (reason, self._now())
        member.session = None
        self._members.pop(member.identity, None)
        # A clone that will not die is the watchdog's problem, not the caller's:
        # the session is over either way, and reap_orphans comes back for the
        # remains.
        with contextlib.suppress(Exception):
            member.clone.destroy()


def slot_claims_held() -> list:
    """Every walk-in slot claim this session holds — the teardown check."""
    import subprocess

    proc = subprocess.run([claims.kh_claim_bin(), "ls", "--mine"], capture_output=True, text=True, check=False)
    return [ln for ln in proc.stdout.splitlines() if claims.SLOT_CLASS in ln or "port/54" in ln]
