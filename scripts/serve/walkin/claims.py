"""`kh-claim` from Python: "it exists" is not "it is mine" (rule 7).

Two things this module refuses to do, both of them the rule:

* **Never check-then-create.** Allocating a slot does not list the taken ones and
  pick a gap; it *attempts* the claim on each slot in turn and keeps the first
  one that succeeded. `kh-claim take` is a `mkdir`, so the attempt IS the
  arbitration, and two brokers racing the same free slot cannot both win.
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

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import naming

SLOT_CLASS = "walkin-slot"
PORT_CLASS = "port"


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


def take(klass: str, name: str, purpose: str = "") -> Claim:
    proc = _run(["take", klass, str(name), "--purpose", purpose or "walkin broker"])
    if proc.returncode != 0:
        raise ClaimError(f"kh-claim refused {klass}/{name}: {(proc.stderr or proc.stdout).strip()}")
    return Claim(klass, str(name))


def try_take(klass: str, name: str, purpose: str = "") -> Claim | None:
    try:
        return take(klass, name, purpose)
    except ClaimError:
        return None


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
    for slot in candidates:
        naming.check_slot(slot)
        got = try_take(SLOT_CLASS, slot, f"walkin clone {identity}")
        if not got:
            continue
        port = try_take(PORT_CLASS, naming.udp_port(slot), f"walkin clone {identity}")
        if not port:
            got.release()
            continue
        return SlotClaim(slot=slot, claims=(got, port))
    raise ClaimError(
        f"no free walk-in slot in {naming.SLOT_MIN}-{naming.SLOT_MAX} for {identity} "
        "— the pool is at its ceiling, or a reap is overdue"
    )
