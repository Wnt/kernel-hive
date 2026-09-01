"""Transactional per-station cutover: materialize beside, flip once, stamp.

WHY THIS SHAPE. The fix for order-sensitivity is to stop doing ordered in-place
installs at all. Today a station's binary, launcher, daemon and env fixture must
land in a specific order, in both directions, enforced by discipline only — and
on 2026-08-30 that discipline was the thing that failed: `-device kh-ramabs` on
an older binary is an unknown device and QEMU refuses to start, while
`SH_INPUT_BACKEND=ramabs` on an older daemon panics it at startup. Two opposite
ordering constraints, held in a human's head.

A closure directory removes the constraint rather than automating it. Every
member is materialized BESIDE the running set, touching nothing live; then one
`rename(2)` of a symlink swaps the whole set. There is no instant at which a new
launcher can meet an old binary, so "is this change inert?" — a question judged
per-file, wrongly, on 2026-08-30 — stops being a question anyone has to answer.
Partial application is unrepresentable.

ROLLBACK IS THE SAME ONE FLIP, and it is COMPLETE where a field-by-field revert
is not. Reverting that station's backend without also restoring its cursor scale
would have left it streaming with a silently wrong pointer gain and nothing
failing. The closure flip makes that mistake unrepresentable too: the whole set
reverts, or none of it does.

THREE REFUSALS, all enforced rather than remembered:
  * a root under the live serving tree (store.LiveRootRefused);
  * any member that is live state of record (denylist.refuse_if_protected);
  * a fleet whose deployed rows are not all claimed by a unit — because a row
    no unit owns is converged by nobody, forever, and a reconciler that writes
    while blind to a third of the fleet is worse than no reconciler.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

from .denylist import refuse_if_protected
from .store import ObjectStore, refuse_live_root

# Ordered most-disruptive first: a closure diff takes the highest class any of
# its members implies. Getting this wrong is visitor-facing, so the mapping is
# explicit rather than inferred.
RECAPTURE = "recapture-required"
SERVE_RESTART = "serve-restart"
RESTART = "restart-required"
CONFIG_RELOAD = "config-reload"
MANIFEST_ONLY = "manifest-only"
CLASS_ORDER = (RECAPTURE, SERVE_RESTART, RESTART, CONFIG_RELOAD, MANIFEST_ONLY)


def classify_member(path: str) -> str:
    """The disruption a single changed member implies."""
    name = path.rsplit("/", 1)[-1]
    # A launcher or device-set change invalidates the checkpoint: golden,
    # binary and device set are ONE combination (AGENTS.md rule 6), so this
    # can never be automatic.
    if name in ("qemu-streamhost.sh", "x11-runtime.sh") or name.endswith(".launch.sh"):
        return RECAPTURE
    if path.startswith(("scripts/serve/", "spa/")):
        return SERVE_RESTART
    if path.startswith("streamhost/streamhost/") or name in ("Cargo.toml", "Cargo.lock"):
        return RESTART
    if name.endswith((".env", ".service", ".conf")) or name == "tile.env":
        return RESTART
    if path.startswith(("registry/generated/", "build/registry/")):
        return MANIFEST_ONLY
    if path.startswith("registry/"):
        return MANIFEST_ONLY
    return RESTART


def classify(changed: list[str]) -> str:
    """The class of a whole closure diff: the most disruptive member wins."""
    if not changed:
        return MANIFEST_ONLY
    classes = {classify_member(p) for p in changed}
    for level in CLASS_ORDER:
        if level in classes:
            return level
    return RESTART


class UnitRoot:
    """One unit's on-disk layout under a (sandbox) root."""

    def __init__(self, root: Path, unit: str):
        refuse_live_root(root)
        self.root = Path(root)
        self.unit = unit
        self.dir = self.root / "units" / unit.replace(":", "__")
        self.releases = self.dir / "releases"
        self.current = self.dir / "current"
        self.applied = self.dir / ".applied"
        self.journal = self.dir / "journal.jsonl"

    # ---- journal ---------------------------------------------------------
    def record(self, step: str, **fields) -> None:
        """Append one step. A crash at any point is resumable from this file,
        which is checkpoint-guard's idiom generalized: nothing is deleted until
        the replacement is accepted."""
        self.dir.mkdir(parents=True, exist_ok=True)
        row = {"ts": time.time(), "unit": self.unit, "step": step, **fields}
        with self.journal.open("a") as fh:
            fh.write(json.dumps(row) + "\n")
            fh.flush()
            os.fsync(fh.fileno())

    def history(self) -> list[dict]:
        if not self.journal.exists():
            return []
        return [json.loads(line) for line in self.journal.read_text().splitlines() if line.strip()]

    # ---- state -----------------------------------------------------------
    def applied_hash(self) -> str | None:
        if not self.applied.exists():
            return None
        try:
            return json.loads(self.applied.read_text()).get("closure")
        except (OSError, ValueError):
            return None

    def current_release(self) -> Path | None:
        return self.current.resolve() if self.current.is_symlink() else None

    def release_dirs(self) -> list[Path]:
        return sorted(self.releases.iterdir()) if self.releases.exists() else []


def materialize(unit_root: UnitRoot, store: ObjectStore, members: dict[str, bytes], closure: str) -> Path:
    """Build the complete new closure BESIDE the running one. Touches nothing live."""
    release = unit_root.releases / closure.replace("sha256:", "")
    unit_root.record("materialize-begin", closure=closure, members=len(members))
    for path, data in members.items():
        refuse_if_protected(path, "closure member")
        digest = store.add_bytes(data)
        store.materialize(digest, release / path)
    manifest = {
        "closure": closure,
        "members": {p: store.add_bytes(d) for p, d in members.items()},
        "materializedAt": time.time(),
    }
    (release / "closure.json").write_text(json.dumps(manifest, indent=2, sort_keys=True))
    unit_root.record("materialize-done", closure=closure, release=str(release))
    return release


def flip(unit_root: UnitRoot, release: Path, closure: str, commit: str) -> None:
    """THE atomic switch: one rename(2) of a symlink.

    Written to a temp name in the same directory and renamed over `current`, so
    a reader either sees the whole old closure or the whole new one. There is no
    window in which `current` is missing, which matters because a launcher that
    resolves through it would otherwise fail during the swap.
    """
    unit_root.record("flip-begin", closure=closure, to=str(release))
    tmp = unit_root.dir / f".current.tmp.{os.getpid()}"
    if tmp.exists() or tmp.is_symlink():
        tmp.unlink()
    tmp.symlink_to(release)
    os.replace(tmp, unit_root.current)
    unit_root.applied.write_text(json.dumps({"closure": closure, "commit": commit, "at": time.time()}, indent=2))
    unit_root.record("flip-done", closure=closure, commit=commit)


def rollback(unit_root: UnitRoot, commit: str = "rollback") -> str | None:
    """Flip back to the previous accepted closure. The same one operation.

    Returns the closure rolled back to, or None if there is nothing to go back
    to — in which case NOTHING is changed, because a rollback that leaves a
    station with no closure at all is worse than the failure it answers.
    """
    history = unit_root.history()
    flips = [r for r in history if r["step"] == "flip-done"]
    if len(flips) < 2:
        unit_root.record("rollback-refused", why="no previous accepted closure")
        return None
    previous = flips[-2]["closure"]
    release = unit_root.releases / previous.replace("sha256:", "")
    if not release.exists():
        unit_root.record("rollback-refused", why=f"release for {previous} is gone")
        return None
    unit_root.record("rollback-begin", to=previous)
    flip(unit_root, release, previous, commit)
    unit_root.record("rollback-done", to=previous)
    return previous


def resume_needed(unit_root: UnitRoot) -> bool:
    """Did a cutover die between materialize and flip?

    The journal's last step tells you, which is the whole reason each step is
    recorded before it is attempted rather than after it succeeds.
    """
    history = unit_root.history()
    if not history:
        return False
    return history[-1]["step"] in ("materialize-begin", "flip-begin", "rollback-begin")
