#!/usr/bin/env python3
"""Deployed Python must not import a scripts/lib/ module that no box-sync pair carries.

The outage this closes, 2026-08-23: a stream added scripts/lib/guest_wake.py and
imported it from scripts/labctl.d/common.py. common.py has a box-sync pair (the
`scripts/labctl.d/*.py` tree loop generates one per file); guest_wake.py did not,
because scripts/lib/ falls OUTSIDE that loop. The module therefore reached the box
CHECKOUT and never the installed tree -- and scripts/labctl prefers the deployed
tree over the checkout, so the moment the commit was deployed every labctl verb on
the box died in the import, before it parsed a single argument. Box-wide, with no
workaround; it took a coordinator deploy to recover.

That is the same shape as the two other DEPLOYED-INVISIBLE failures of the same
night -- rn-tapnet.sh (a launcher-called helper with no pair, already guarded in
stations_registry/validate_retronet.py) and a missing pre-push hook. A helper
reaches the box checkout but never the place that runs it.

THE RULE, and it is decidable without running or deploying anything: for every
Python file that HAS a box-sync pair, resolve its imports against scripts/lib/;
if a resolved module has no pair of its own, fail. That covers the transitive case
for free -- a paired lib module importing an unpaired one is the identical bug one
level down, and since every paired module is itself a subject here it is caught in
its own right rather than needing a graph walk.

Deliberately NOT checked, and why, so a later session does not "helpfully" widen
this into the thing that gets it deleted:

  * "Every file in scripts/lib/ must have a pair." This is the tempting rule and
    it is wrong. scripts/lib/ legitimately holds plenty that never ships:
    build-time-only helpers (xvfb-alloc's callers), and shell libraries that ship
    only through bespoke pairs to renamed destinations (clone-guard.sh ->
    /usr/local/bin/clone-guard, kh-claim.sh -> /usr/local/bin/kh-claim). A blanket
    rule fires on every one of them, so it would be silenced by the next agent who
    tripped over it and the debt would come straight back. We key on IMPORTS, and
    fire only on a positive contradiction: this paired file imports that module,
    and that module has no pair.
  * Whether the pair's DESTINATION is somewhere the importer can actually reach.
    guest_wake.py installs flat into /usr/local/lib/labctl/ beside common.py, which
    is why common.py searches its own directory -- but callers legitimately extend
    sys.path themselves (scripts/dev/qmp-type.py appends scripts/lib), so a
    same-directory requirement would be wrong for a correct file. A pair pointing
    somewhere useless is a narrower bug than no pair at all, and no instance of it
    has been observed.
  * Shell: a deployed script sourcing a scripts/lib/*.sh with no pair. Checked by
    hand and NOT implemented, on evidence: no deployed shell sources scripts/lib/
    at all today (box-install.sh sources box-sync-pairs.sh, but it runs from the
    repo checkout, not from the box), and the shell pairs RENAME their destination,
    so "has a pair" is not even the right predicate there -- the sourcing path
    would have to match the install path. Implementing it now would be a rule with
    zero instances and a built-in false-positive mode. The station-launcher half of
    that shape is already covered by validate_retronet.py's rn-tapnet check.
  * Imports that resolve to stdlib or the venv.

SAME-DIRECTORY SIBLINGS ARE CHECKED TOO, since 2026-08-31, and this paragraph
used to say the opposite. It read: "a sibling in the importer's own directory
(which the pair loops already carry as a tree)". That is true for
scripts/labctl.d/, scripts/serve/auth/, authui/ and walkin/ -- and FALSE for
top-level scripts/serve/, which is a STATIC NAME LIST. scripts/serve/
deploy_hint.py landed in exactly that gap: imported at module scope by
osgallery-https-server.py, no row of its own, so installing the importer alone
would have stopped the serving plane from starting -- strictly worse than the
scripts/lib/ outage this file was written for. A human caught it by looking up a
pair label by hand.

The reasoning that excluded siblings was sound about the directories it had in
mind and wrong about the one it did not enumerate, which is the more dangerous
shape of wrong: it did not merely miss a case, it explained why the case could
not happen. The predicate is unchanged -- fire only on a positive contradiction,
this paired file imports that file and that file has no pair -- so a directory
genuinely covered by a tree loop stays silent without this check needing to know
which loops exist.

Repo-only and static: no ssh, no box access, so CI and a public clone stay green.
Run standalone, or via `make station-registry-check`.
"""

from __future__ import annotations

import ast
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PAIRS = REPO / "scripts/lib/box-sync-pairs.sh"
# The table is a FAMILY: box-sync-pairs.sh hit its 600-line hard cap, so the
# per-station network-link rows were split into box-sync-pairs-retronet.sh.
# Read every sibling, or a split silently blinds this check.
PAIRS_FAMILY = sorted((REPO / "scripts/lib").glob("box-sync-pairs*.sh"))


def pairs_text() -> str:
    return "\n".join(f.read_text(encoding="utf-8") for f in PAIRS_FAMILY)


LIB = REPO / "scripts/lib"
LIB_REL = "scripts/lib"

# box-sync-pairs.sh is shell, and sourcing it is not an option here: its loader
# makes read-only ssh round trips to labhost for the .rs and registry tree unions,
# which this check must never do. So the rows are parsed, exactly the way
# stations_registry/validate_retronet.py already parses the same file for its
# rn-tapnet rows. Three constructs produce the repo-side path of a row:
#
#   1. a literal row          box_sync_add_pair <label> <repo-path> <box-path> ...
#   2. a `git ls-files` tree  while read rel; ... done < <(git ... ls-files 'GLOB')
#   3. a name-list loop       for name in A B C; do ... "PREFIX/$name" ...
#
# Anything with a $ in the repo-side argument that none of these explains is a row
# this parser cannot see. That is a blind spot, not a pass, so ANCHORS below turn
# it into a loud failure instead of a quiet green.
ROW = re.compile(r"^\s*box_sync_add_pair\s+(\S+)\s+(\S+)\s+(\S+)", re.M)
LS_FILES = re.compile(r"git\s+-C\s+\"\$REPO\"\s+ls-files\s+([^\n|]+)")
GLOB = re.compile(r"'([^']+)'")
FOR_LOOP = re.compile(
    r"for\s+name\s+in\s+((?:[^;\n]|\\\n)+?);\s*do(.*?)done",
    re.S,
)
PREFIX_ARG = re.compile(r'box_sync_add_pair\s+\S+\s+"([^"$]*)/\$name"')

# Paths that MUST resolve to a pair for the parser to be believed. Each comes from
# a different construct above (literal row, ls-files tree, name-list loop), so if a
# restructuring of box-sync-pairs.sh blinds one of them this check fails loudly
# rather than passing vacuously on an empty set -- "it exists" is not "it is mine".
# They are deliberately NOT the modules under test: an anchor that is also a
# subject turns a real finding into a parser complaint, and would go off the day
# such a module is legitimately retired.
ANCHORS = (
    "scripts/labctl",  # literal row
    "scripts/labctl.d/common.py",  # ls-files tree loop
    "scripts/serve/check-stream-tickets.py",  # name-list loop
)


def paired_repo_paths(text: str) -> set[str]:
    """Repo-relative paths that box-sync-pairs.sh registers a pair for."""
    paths: set[str] = set()
    for _label, repo_path, _box_path in ROW.findall(text):
        cleaned = repo_path.strip('"')
        if "$" not in cleaned:
            paths.add(cleaned)
    for args in LS_FILES.findall(text):
        globs = GLOB.findall(args)
        if not globs:
            continue
        listed = subprocess.run(
            ["git", "-C", str(REPO), "ls-files", *globs],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.split()
        paths.update(listed)
    for words, body in FOR_LOOP.findall(text):
        prefixes = PREFIX_ARG.findall(body)
        if not prefixes:
            continue
        for word in words.replace("\\\n", " ").split():
            for prefix in prefixes:
                paths.add(f"{prefix}/{word}")
    return paths


def imported_names(path: Path) -> set[str]:
    """Top-level module names `path` imports, ignoring relative imports."""
    names: set[str] = set()
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and not node.level and node.module:
            names.add(node.module.split(".")[0])
    return names


def resolves_to_lib(importer: Path, name: str) -> Path | None:
    """The scripts/lib/ module `name` resolves to from `importer`, if any.

    A sibling in the importer's own directory wins first, the way Python resolves
    it and the way the flat install lays it out -- that is what keeps this from
    claiming scripts/serve/config.py for a `import config`. The exception is an
    importer that already lives IN scripts/lib: there a sibling IS the lib case,
    and skipping it would drop exactly the transitive bug this walks for.
    """
    candidate = LIB / f"{name}.py"
    if not candidate.exists():
        return None
    if importer.parent != LIB and (importer.parent / f"{name}.py").exists():
        return None
    return candidate


def resolves_to_sibling(importer: Path, name: str) -> Path | None:
    """A module in the importer's OWN directory, as a package or a module.

    WHY THIS IS CHECKED AND NOT ASSUMED SAFE. The docstring above used to
    dismiss siblings on the grounds that "the pair loops already carry [them] as
    a tree". That is true for scripts/labctl.d/, scripts/serve/auth/,
    authui/ and walkin/ — and FALSE for top-level scripts/serve/, which is a
    STATIC NAME LIST. So a new module dropped beside osgallery-https-server.py
    and imported by it has no pair, and the assumption that made it unnecessary
    to look was the whole gap.

    Measured 2026-08-31: scripts/serve/deploy_hint.py, imported at module scope
    by scripts/serve/osgallery-https-server.py, had no row. Installing the
    importer without it does not drift — the serving plane fails to start, which
    is strictly worse than the scripts/lib/ outage this file was written for.
    It was caught by a human looking up a pair label by hand.

    Same predicate as the lib case, and the same principle: fire only on a
    positive contradiction — this paired file imports that file, and that file
    has no pair. A directory genuinely covered by a tree loop always has one, so
    this is silent there rather than needing to know which loops exist.
    """
    if importer.parent == LIB:
        return None  # already the resolves_to_lib case, transitively walked
    for candidate in (
        importer.parent / f"{name}.py",
        importer.parent / name / "__init__.py",
    ):
        if candidate.exists():
            return candidate
    return None


def main() -> int:
    if not PAIRS.exists():
        print(f"deploy-pair-imports: {PAIRS.relative_to(REPO)} is missing", file=sys.stderr)
        return 2
    paired = paired_repo_paths(pairs_text())
    missing_anchors = [a for a in ANCHORS if a not in paired]
    if missing_anchors:
        print(
            f"deploy-pair-imports: cannot read {PAIRS.relative_to(REPO)} — no pair found for "
            f"{missing_anchors}, which are known-deployed files used here as parser anchors. "
            "The row syntax changed underneath this check, so its green means nothing. Teach "
            f"paired_repo_paths() the new construct in {Path(__file__).relative_to(REPO)}.",
            file=sys.stderr,
        )
        return 2

    errors: list[str] = []
    walked = 0
    # Transitivity needs no graph walk: EVERY paired .py is a subject here, so a
    # paired lib module that imports an unpaired one is reported directly against
    # itself. The only way to reach an unpaired lib module is through the error
    # below, so there is no deeper chain to follow.
    for rel in sorted(paired):
        importer = REPO / rel
        if not rel.endswith(".py") or not importer.exists():
            continue
        walked += 1
        for name in sorted(imported_names(importer)):
            sibling = resolves_to_sibling(importer, name)
            if sibling is not None:
                target = str(sibling.relative_to(REPO))
                if target not in paired:
                    errors.append(
                        f"{rel}: imports `{name}`, which resolves to its SIBLING {target} — "
                        f"and {target} has no `box_sync_add_pair` row. {rel} IS deployed, so "
                        f"installing it without {target} does not merely drift: the deployed "
                        f"copy dies in this import and its plane never starts. Directories "
                        f"carried by a tree loop cannot hit this; the top-level "
                        f"scripts/serve/ list is a STATIC NAME LIST, so a new module beside a "
                        f"deployed one needs its name added there explicitly."
                    )
                continue
            module = resolves_to_lib(importer, name)
            if module is None:
                continue
            target = str(module.relative_to(REPO))
            if target in paired:
                continue
            errors.append(
                f"{rel}: imports `{name}`, which resolves to {target} — and {target} has "
                f"no `box_sync_add_pair` row in {PAIRS.relative_to(REPO)}. {rel} IS "
                f"deployed, so {target} reaches the box CHECKOUT and never the installed "
                f"tree, and the first thing the deployed copy does is die in this import. "
                f"Add a row to the scripts/lib block, installing it where the importer "
                f"looks — the labctl tree installs flat, so for a labctl.d/ importer that is:\n"
                f"      box_sync_add_pair {module.stem} {target} "
                f"/usr/local/lib/labctl/{module.name} exact repo\n"
                f"    — or, if {target} is genuinely build-time-only, do not import it from "
                f"a deployed file."
            )

    if errors:
        print("deploy-pair-imports: FAIL", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    print(
        f"deploy-pair-imports: OK ({walked} deployed python file(s) walked; "
        f"{LIB_REL} imports and same-directory siblings all paired)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
