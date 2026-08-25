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

from . import naming

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
    """Take one free slot in 152-200, with its UDP port, or raise.

    `preferred` re-takes a specific slot (a respawn keeping its own number, so a
    visitor's reconnect does not chase a moving port); it is still a take, not a
    check, so a preferred slot someone else holds fails like any other.
    """
    candidates = [preferred] if preferred else range(naming.SLOT_MIN, naming.SLOT_MAX + 1)
    reasons = set()
    for slot in candidates:
        naming.check_slot(slot)
        got, why = try_take(SLOT_CLASS, slot, claim_purpose(identity), exclusive=True)
        if not got:
            reasons.add(why)
            continue
        port, why = try_take(PORT_CLASS, naming.udp_port(slot), claim_purpose(identity), exclusive=True)
        if not port:
            got.release()
            reasons.add(why)
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
