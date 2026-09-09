"""Run the box-sync pair self-check when, and only when, the table CHANGED.

`scripts/lib/box-sync-pairs.sh` declares every repo→box mirror pair, and until
2026-09-03 the only reader was the gate, which needs labhost. So a bad row was
invisible until a deploy or a station that would not start.
`scripts/dev/box-sync-pairs-selfcheck.sh` answers the same questions offline;
this hooks it into `stations-registry.py validate`.

It is conditional on purpose. The self-check sources the whole loader and walks
439 rows — cheap, but not free, and its answer is a property of files most
changes never touch. Running it only when a `box-sync-pairs*.sh` file differs
from HEAD in the working tree keeps `validate` fast and keeps the failure where
its author can fix it, which is the same scoping rule the pre-push gate uses
(docs/lab/AGENT-CI-EXIT-RULE.md: a gate must be satisfiable by the person it
blocks). `KH_PAIRS_SELFCHECK=always` forces it; `=never` skips it.
"""

from __future__ import annotations

import os
import subprocess
from typing import Any

from .constants import REPO

SELFCHECK = REPO / "scripts/dev/box-sync-pairs-selfcheck.sh"
PAIRS_GLOB = "scripts/lib/box-sync-pairs*.sh"


def pairs_files_changed() -> list[str]:
    """Pair-table files with uncommitted changes (modified, staged or untracked)."""
    changed: set[str] = set()
    for args in (["diff", "--name-only", "HEAD", "--"], ["ls-files", "--others", "--exclude-standard", "--"]):
        try:
            out = subprocess.run(
                ["git", "-C", str(REPO), *args, PAIRS_GLOB],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError:  # pragma: no cover - no git in a source tarball
            return []
        changed.update(line for line in out.stdout.split("\n") if line.strip())
    return sorted(changed)


def validate_pairs(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """(c) the pairs self-check, when box-sync-pairs*.sh changed in this tree."""
    del rows  # the pair table is not a registry document; it is checked as a whole
    mode = os.environ.get("KH_PAIRS_SELFCHECK", "auto")
    if mode == "never":
        return
    changed = pairs_files_changed()
    if mode != "always" and not changed:
        return
    if not SELFCHECK.is_file():  # pragma: no cover - only in a partial checkout
        errors.append(f"{PAIRS_GLOB} changed but {SELFCHECK.relative_to(REPO)} is missing")
        return
    # box_sync_load_pairs builds the registry tree union by RENDERING the
    # registry (`stations-registry.py render`), and render() calls validate() —
    # so without this the check re-enters itself forever. Measured, not feared:
    # the first run of this hook wedged in exactly that loop.
    env = dict(os.environ, KH_PAIRS_SELFCHECK="never")
    result = subprocess.run(
        ["bash", str(SELFCHECK)],
        capture_output=True,
        text=True,
        check=False,
        cwd=str(REPO),
        env=env,
    )
    if result.returncode == 0:
        return
    detail = (result.stdout + result.stderr).strip() or f"exit {result.returncode}"
    errors.append(
        f"box-sync pair self-check failed (this tree changes {', '.join(changed) or PAIRS_GLOB}):\n"
        + "\n".join(f"      {line}" for line in detail.splitlines())
    )
