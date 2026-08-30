"""Closure hashes: desired state as a pure function of the pushed commit.

A unit's CLOSURE HASH is a digest of the exact member set it runs under — every
member's repo path and the blob the commit holds for it. Converged means the
applied stamp equals the desired hash; nothing else.

Two properties this file exists to guarantee, both tested:

* **It reads git objects, never the working tree.** Desired state is a property
  of a COMMIT. Hashing the checkout would make an agent's uncommitted edit look
  like desired state, which is the "live state tested as a property of a commit"
  confusion the whole design removes, inverted.
* **It is a read path, so it never writes.** The 2026-08-24 incident where a
  dry-run plan fast-forwarded the shared checkout — moving every other session's
  drift baseline — is the reason `plan` and `status` are pure reads. There is a
  test that runs the CLI under an audit hook and asserts zero writes.

The hash covers member PATHS as well as contents, so removing a member changes
the closure. A digest of contents alone would call a unit converged after a file
was dropped from it, which is precisely how the `boot/` tree was once lost for a
week: absence is a change.
"""

from __future__ import annotations

import hashlib

CLOSURE_VERSION = "kh-closure-v1"


def closure_hash(members: dict[str, str]) -> str:
    """members: path -> blob sha. Stable, order-independent, absence-sensitive."""
    h = hashlib.sha256()
    h.update(CLOSURE_VERSION.encode())
    for path in sorted(members):
        h.update(b"\0")
        h.update(path.encode())
        h.update(b"\0")
        h.update(members[path].encode())
    return f"sha256:{h.hexdigest()}"


def member_blobs(git, commit: str, paths: list[str], cwd=None) -> dict[str, str]:
    """path -> blob sha AT THE COMMIT. Missing paths are simply absent."""
    if not paths:
        return {}
    out = git("ls-tree", "-r", "--format=%(objectname) %(path)", commit, cwd=cwd)
    want = set(paths)
    blobs = {}
    for line in out.splitlines():
        sha, _, path = line.partition(" ")
        if path in want:
            blobs[path] = sha
    return blobs


def unit_closures(git, commit: str, units: dict[str, list[str]], cwd=None) -> dict[str, dict]:
    """unit -> {hash, members, count} for the given commit."""
    result = {}
    for unit, paths in units.items():
        blobs = member_blobs(git, commit, paths, cwd=cwd)
        result[unit] = {
            "hash": closure_hash(blobs),
            "count": len(blobs),
            "missing": sorted(set(paths) - set(blobs)),
        }
    return result
