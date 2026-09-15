"""`kh-claim` from Python: "it exists" is not "it is mine" (rule 7).

Two things this module refuses to do, both of them the rule:

* **Never check-then-create.** Allocating a slot does not list the taken ones and
  pick a gap; it *attempts* the claim on each slot in turn and keeps the first
  one that succeeded. `kh-claim take` is a `mkdir`, so the attempt IS the
  arbitration, and two brokers racing the same free slot cannot both win.
* **Never read a zero exit as "it is mine now".** `kh-claim take` is a mutex
  BETWEEN sessions and idempotent WITHIN one: re-taking a claim your own session
  already holds prints `already yours` and exits 0. That is right for its usual
  caller — a rig re-asserting its own sandbox — and wrong for a slot, because the
  broker is a single `KH_SESSION` and every clone it builds shares it. Read as
  success, it handed slot 152 to all three production clones at once, each
  believing it owned UDP 54152, with one claim directory behind them. So slot and
  port takes are EXCLUSIVE: `already yours` means a sibling clone in this same
  process has it, and that is a refusal, not a success.
* **Never fall back.** A refused claim raises. There is no "reuse it anyway"
  branch, because the thing on the other end of a stolen slot is either another
  agent's rig or another visitor's session.

One slot claim covers the clone's whole set of shared numbers — UDP port, VMID,
MAC octet are all derived from it (`naming.py`) — so ownership is one fact
rather than four that can disagree. The UDP port is claimed as well, in the
conventional `port` class, because other tooling on the box claims ports there
and would otherwise have no way to see that 54154 is spoken for.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import cell, naming

SLOT_CLASS = "walkin-slot"
PORT_CLASS = "port"

# `kh-claim take` says which of the two things it did. The exit code cannot tell
# them apart, so the message is the only signal there is.
_TOOK = re.compile(r"^kh-claim: took ", re.MULTILINE)
_ALREADY_MINE = re.compile(r"already yours", re.MULTILINE)


class ClaimError(RuntimeError):
    """A claim that was refused, or a claim tool that is not there."""


def kh_claim_bin() -> str:
    override = os.environ.get("KH_CLAIM_BIN")
    if override:
        return override
    found = shutil.which("kh-claim")
    if found:
        return found
    repo = Path(__file__).resolve().parents[3] / "scripts" / "lib" / "kh-claim.sh"
    if repo.exists():
        return str(repo)
    raise ClaimError("kh-claim is not on PATH and not in the repo — refusing to allocate anything unclaimed")


def _run(args: list) -> subprocess.CompletedProcess:
    session = os.environ.get("KH_SESSION", "")
    if not session:
        raise ClaimError("KH_SESSION is unset; every walk-in claim must name its owner (rule 7)")
    return subprocess.run(
        [kh_claim_bin(), *args],
        capture_output=True,
        text=True,
        env={**os.environ, "KH_SESSION": session},
        check=False,
    )


@dataclass(frozen=True)
class Claim:
    klass: str
    name: str

    def release(self) -> None:
        _run(["release", self.klass, self.name])


def take(klass: str, name: str, purpose: str = "", exclusive: bool = False) -> Claim:
    """Take a claim, or raise.

    `exclusive` additionally refuses a claim this session already holds — see the
    module docstring. Use it for anything only ONE clone may have.
    """
    proc = _run(["take", klass, str(name), "--purpose", purpose or "walkin broker"])
    if proc.returncode != 0:
        raise ClaimError(f"kh-claim refused {klass}/{name}: {(proc.stderr or proc.stdout).strip()}")
    output = f"{proc.stdout}\n{proc.stderr}"
    if exclusive and not _TOOK.search(output):
        why = "already held by this session (another clone has it)" if _ALREADY_MINE.search(output) else output.strip()
        raise ClaimError(f"kh-claim did not grant {klass}/{name}: {why}")
    return Claim(klass, str(name))


def try_take(klass: str, name: str, purpose: str = "", exclusive: bool = False) -> tuple:
    """`(claim, reason)` — exactly one of which is set.

    The reason is kept because the allocation loop's failure message is otherwise
    a lie: with `KH_SESSION` unset in the serving unit every single take failed
    for that one reason, and the loop reported "no free slot in 152-200" against
    a claim class with nothing in it. An exhaustion message that cannot tell
    "the pool is full" from "I am not allowed to ask" sends its reader to the
    wrong half of the system, which is what it did.
    """
    try:
        return take(klass, name, purpose, exclusive=exclusive), ""
    except ClaimError as exc:
        return None, str(exc)


def mine(klass: str = "") -> list:
    """Every claim this session holds, optionally filtered to one class."""
    proc = _run(["ls", "--mine", "--json"])
    try:
        rows = json.loads(proc.stdout or "[]")
    except ValueError:
        return []
    return [row for row in rows if not klass or row.get("class") == klass]


def everyone(klass: str = "") -> list:
    """Every claim in the registry, EVERY session — the box-wide truth.

    The reapers read this, not `mine()`: a tap or cell sweep that knows only
    its own members will destroy another broker's kernel objects. Measured
    2026-08-26: the production watchdog reaped a dev broker's nine taps within
    one 15-second tick of their creation, because to it they were orphans.
    """
    proc = _run(["ls", "--json"])
    try:
        rows = json.loads(proc.stdout or "[]")
    except ValueError:
        return []
    return [row for row in rows if not klass or row.get("class") == klass]


def release(klass: str, name: str, force: bool = False) -> None:
    _run(["release", klass, str(name), *(["--force"] if force else [])])


def claim_purpose(identity: str) -> str:
    """`walkin clone <identity> @ <clone root>`.

    The root is in there because the SESSION NAME is not unique: a dev sandbox
    and the production serving unit can both run as `walkin-broker`, and then
    each one's `kh-claim ls --mine` lists the other's claims. Without the root a
    reconciler on one side would see the other side's claim for an identity it
    has never heard of, decide it was a stray, and release a slot out from under
    a running clone. The root is the thing that actually differs.
    """
    return f"walkin clone {identity} @ {naming.WALKIN_ROOT}"


def purpose_root(purpose: str) -> str:
    """The clone root a claim's purpose names, or "" for one that names none."""
    _, sep, root = (purpose or "").partition(" @ ")
    return root.strip() if sep else ""


def purpose_identity(purpose: str) -> str:
    head = (purpose or "").partition(" @ ")[0]
    return head.replace("walkin clone ", "").strip()


@dataclass(frozen=True)
class SlotClaim:
    slot: int
    claims: tuple

    def release(self) -> None:
        for claim in self.claims:
            claim.release()


def claim_slot(identity: str, preferred: int | None = None) -> SlotClaim:
    """Take one free slot in `naming.SLOT_MIN`-`naming.SLOT_MAX`, with its UDP
    port, or raise.

    `preferred` re-takes a specific slot (a respawn keeping its own number, so a
    visitor's reconnect does not chase a moving port); it is still a take, not a
    check, so a preferred slot someone else holds fails like any other.

    **The ledger is asked, and so is the machine.** `kh-claim` arbitrates
    correctly between two callers that both hold a claim — but a slot whose
    running clone lost its claim (a stray release, an outage, a broker that
    built outside this module) looks EMPTY to the ledger while a real guest
    sits on it. Measured 2026-09-14: a station agent's own walk-in tooling,
    pointed at a redirected `WALKIN_ROOT`, asked for a slot in this exact
    range, found `walkin-slot/259` unclaimed, and was handed the number a LIVE
    production `walkin-os2warp-4` was already running on — the clone was never
    touched only because the agent noticed and released before building
    anything. `cell.live_cells()` reads `wibr<slot>` bridges straight from the
    kernel, which exists for as long as the clone's network cell does,
    independent of which `WALKIN_ROOT` claimed it or whether its claim
    survived. A slot the kernel says is live is refused here whatever the
    ledger says — read once before the loop (the common case resolves on the
    first free slot, so a snapshot per candidate would mostly cost time for no
    benefit), and read AGAIN right after a successful take, closing the
    narrow window between that snapshot and the claim actually landing.
    """
    candidates = [preferred] if preferred else range(naming.SLOT_MIN, naming.SLOT_MAX + 1)
    reasons = set()
    live_at_start = set(cell.live_cells())
    for slot in candidates:
        naming.check_slot(slot)
        if slot in live_at_start:
            reasons.add(
                f"slot {slot} already carries a live cell (wibr{slot}) in the kernel "
                "— the ledger may not know, the machine is not lying"
            )
            continue
        got, why = try_take(SLOT_CLASS, slot, claim_purpose(identity), exclusive=True)
        if not got:
            reasons.add(why)
            continue
        port, why = try_take(PORT_CLASS, naming.udp_port(slot), claim_purpose(identity), exclusive=True)
        if not port:
            got.release()
            reasons.add(why)
            continue
        if slot in cell.live_cells():
            # Grew live between the snapshot above and this claim landing.
            # Give both claims straight back — never hand out a slot a guest
            # is already running on because we won a race against the ledger.
            got.release()
            port.release()
            reasons.add(
                f"slot {slot} grew a live cell (wibr{slot}) while being claimed "
                "— refusing rather than double-booking it"
            )
            continue
        return SlotClaim(slot=slot, claims=(got, port))
    if len(reasons) == 1:
        # Every attempt failed the same way, which means the range was never the
        # problem. Say what actually happened instead of describing a full pool.
        raise ClaimError(f"could not claim any walk-in slot for {identity}: {reasons.pop()}")
    raise ClaimError(
        f"no free walk-in slot in {naming.SLOT_MIN}-{naming.SLOT_MAX} for {identity} "
        "— the pool is at its ceiling, or a reap is overdue"
    )


def walkin_claims_held() -> list:
    """Every walk-in slot and port claim this session holds — the teardown check.

    Rule 8's "the check that proved it", as one call: a hold that lapsed, a
    clone that was destroyed and a pool that was emptied all have to show up
    here as NOTHING LEFT, and `kh-claim ls --mine` is the only thing that knows.
    Lived in `broker.py` until 2026-09-15, where it had no caller and was the
    wrong layer; the walk-in smoke check is the caller it was written for.
    """
    proc = _run(["ls", "--mine"])
    return [ln for ln in proc.stdout.splitlines() if SLOT_CLASS in ln or f"{PORT_CLASS}/54" in ln]
