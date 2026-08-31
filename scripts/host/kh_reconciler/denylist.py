"""Live state of record: bytes owned by NEITHER git nor the convergence loop.

The design has two kinds of bytes — desired state (a pure function of the
commit) and derived artifacts (loop-rendered). There is a third, and the serve
units sit directly on top of its most dangerous instance.

`/data/vms/streamhost/serve/auth-state.json` (root 0600) holds every account,
every passkey credential, every walk-in handle, the walk-in access switch and
the drain flag — INSIDE the directory the serve units are defined over, a few
lines from where today's deploy already does `rm -rf` on sibling trees.
`darklaunch.d/` overlays are the same category.

**A golden can be recaptured. A passkey cannot be regenerated, and a walk-in
handle IS the account.** So this category is never a closure member, never
materialized, never rolled back and never GC'd — and that is enforced here as a
STRUCTURAL property rather than a rule people remember. `closure.py` runs every
candidate member through `refuse_if_protected`, which raises. A future author
who widens a unit's glob to swallow `serve/` gets an exception naming this file,
not a silent deletion.

THE SECOND EXCEPTION, AND WHY IT IS PERMANENT. `access: closed|invited|open`
and `drain` live in that same file. They are operator runtime state and are out
of scope for convergence FOREVER, because the failure mode of a future
reconciler deciding the switch is registry-derived is the worst one available:
**a `git push` opening the walk-in plane to the internet.** The scrub map was
exception one; this is exception two; the list is closed, and adding to it is a
design change rather than a config change.
"""

from __future__ import annotations

import re

# Matched against BOX-ABSOLUTE paths, and against repo-relative paths for the
# repo-side half. Patterns, not literals, because the rotations are dated:
# auth-state.json.2026-08-30 is exactly as unrecoverable as auth-state.json.
PROTECTED = (
    r"(^|/)auth-state\.json(\.[0-9A-Za-z:_.-]+)?$",
    r"(^|/)darklaunch\.d(/|$)",
    r"(^|/)auth-state\.json\.bak(\.[0-9A-Za-z:_.-]+)?$",
    r"(^|/)walkin-state\.json(\.[0-9A-Za-z:_.-]+)?$",
)

_PROTECTED_RE = tuple(re.compile(p) for p in PROTECTED)

# Field names that must never be derived from a commit, wherever they appear.
NEVER_DERIVED = ("access", "drain")


class ProtectedPathError(RuntimeError):
    """Raised when live state of record is about to be treated as deployable."""


def is_protected(path: str) -> bool:
    """True if `path` is live state of record — never a closure member."""
    text = str(path)
    return any(rx.search(text) for rx in _PROTECTED_RE)


def refuse_if_protected(path: str, why: str = "closure member") -> None:
    if is_protected(path):
        raise ProtectedPathError(
            f"refusing to treat {path!r} as a {why}: it is LIVE STATE OF RECORD. "
            "A golden can be recaptured; a passkey cannot be regenerated and a walk-in handle "
            "IS the account. See scripts/host/kh_reconciler/denylist.py and "
            "docs/lab/CONTINUOUS-DEPLOY-PROPOSAL.md 1."
        )


def filter_members(paths, why: str = "closure member") -> list[str]:
    """Every path, having proved none of them is state of record.

    Deliberately RAISES rather than silently dropping. A silent drop would make
    a widened glob look like it worked, and the whole point is that the mistake
    is unrepresentable rather than merely discouraged.
    """
    out = []
    for path in paths:
        refuse_if_protected(path, why)
        out.append(str(path))
    return out
