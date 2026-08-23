#!/usr/bin/env python3
"""The declaration file behind the release notes, and the pins it must agree with.

The emulator patches this project lives on are pushed to public forks and
consumed here as submodules and build pins; which fork, which branch, and who
counts as us is declared by hand in

    registry/release-notes/sources.json

and gathered by release_notes_forks.py. THIS module is the offline half: it
knows where that file lives, and it is the tripwire that keeps the declaration
and the build from drifting apart in silence. `scripts/release-notes.py check`
runs it on every render, so it never touches the network and never reads git —
it is a plain parse of the working tree, and it must stay that way.

THE PIN IS PARSED, NEVER SEARCHED FOR. A branch name survives in comments, echo
lines, docs and `--jq` strings long after the build stopped using it: mame/irix
appears 19 times in one build script alone. A substring scan therefore calls a
repointed build clean — including a repoint onto a branch sources.json
explicitly EXCLUDES, which is the exact damage the citation exists to catch. So
each of the three formats a pin can be written in is parsed for what it really
selects:

    .gitmodules                 a submodule section's `url` + `branch`
    a build script              `<PREFIX>FORK_URL` + `<PREFIX>FORK_BRANCH`
    registry/stations/<id>.json the entry's `emulator.source`

BOTH DIRECTIONS, because either one alone is a one-way tripwire.
`pin_errors()` walks declaration -> build: every branch cites a file, and that
file must still pin it. `undeclared_pins()` walks build -> declaration: every
Wnt/* branch the tree pins must be declared, or every later week is quietly
short of a whole fork. `drift_errors()` is both, and is what `check` calls.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

SOURCES_PATH = Path("registry") / "release-notes" / "sources.json"
SOURCES_NAME = SOURCES_PATH.name

# Where a fork branch can be pinned, and how each format spells it.
SH_FORK_RE = re.compile(r"^[ \t]*(?:export[ \t]+)?(\w*)FORK_(URL|BRANCH)=(\S.*?)[ \t]*$", re.M)
SH_DEFAULT_RE = re.compile(r"^\$\{[A-Za-z_][A-Za-z0-9_]*:-(.*)\}$")
# "github.com/Wnt/es40 main — ...", "github.com/Wnt/qemu @ kernel-hive (...)",
# "build-vice-native.sh (github.com/Wnt/vice kernel-hive/integrated on 3.10.0)".
SOURCE_RE = re.compile(r"github\.com[/:]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)[ \t]*@?[ \t]*([A-Za-z0-9_./-]+)")
# The reverse sweep: build -> declaration. Only the forks we own can be declared.
OUR_FORK_OWNER = "Wnt"
SCAN_GLOBS = ("*.sh", "scripts/**/*.sh", "streamhost/**/*.sh", "registry/stations/*.json")
SKIP_DIRS = frozenset({".git", "node_modules", "third_party"})


def repo_slug(url: str) -> str | None:
    """`https://github.com/Wnt/mame.git` -> `Wnt/mame`. Owner/name, nothing else."""
    text = url.strip().strip("\"'").rstrip("/")
    if text.endswith(".git"):
        text = text[:-4]
    parts = [part for part in text.replace(":", "/").split("/") if part]
    return "/".join(parts[-2:]) if len(parts) >= 2 else None


def _sh_value(raw: str) -> str:
    """`"${VICE_FORK_URL:-https://…}"` -> the default. A shell pin is what the
    build uses when nobody overrides it."""
    text = raw.strip().strip("\"'")
    default = SH_DEFAULT_RE.fullmatch(text)
    if default:
        text = default.group(1)
    return text.strip("\"'")


def gitmodules_pins(text: str) -> set[tuple[str, str]]:
    """Every (repo, branch) a .gitmodules actually pins, per submodule section."""
    pins: set[tuple[str, str]] = set()
    url: str | None = None
    branch: str | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            url = branch = None
            continue
        key, sep, value = stripped.partition("=")
        if not sep:
            continue
        key, value = key.strip(), value.strip()
        if key == "url":
            url = repo_slug(value)
        elif key == "branch":
            branch = value
        if url and branch:
            pins.add((url, branch))
    return pins


def shell_pins(text: str) -> set[tuple[str, str]]:
    """`<PREFIX>FORK_URL` + `<PREFIX>FORK_BRANCH` pairs, matched by prefix."""
    urls: dict[str, str] = {}
    branches: dict[str, str] = {}
    for prefix, kind, raw in SH_FORK_RE.findall(text):
        (urls if kind == "URL" else branches)[prefix] = _sh_value(raw)
    pins = set()
    for prefix, url in urls.items():
        slug, branch = repo_slug(url), branches.get(prefix)
        if slug and branch:
            pins.add((slug, branch))
    return pins


def json_pins(text: str) -> set[tuple[str, str]]:
    """A station registry entry pins its emulator in `emulator.source`."""
    try:
        doc = json.loads(text)
    except json.JSONDecodeError:
        return set()
    source = doc.get("emulator", {}).get("source") if isinstance(doc, dict) else None
    if not isinstance(source, str):
        return set()
    return {(repo_slug(slug) or slug, branch) for slug, branch in SOURCE_RE.findall(source)}


def pins_in(path: Path, text: str) -> set[tuple[str, str]]:
    """Every fork pin a file declares, by the format the file is written in."""
    if path.name == ".gitmodules":
        return gitmodules_pins(text)
    if path.suffix == ".sh":
        return shell_pins(text)
    if path.suffix == ".json":
        return json_pins(text)
    return set()


def _declared(doc: dict) -> tuple[set[tuple[str, str]], dict[tuple[str, str], str]]:
    shipped: set[tuple[str, str]] = set()
    excluded: dict[tuple[str, str], str] = {}
    for fork in doc.get("forks", []):
        repo = fork.get("repo", "?")
        for branch in fork.get("branches", []):
            shipped.add((repo, branch.get("name", "?")))
        for item in fork.get("excludes", []):
            excluded[(repo, item.get("branch", "?"))] = item.get("why", "")
    return shipped, excluded


def _sources_doc(repo_root: Path) -> dict | list[str]:
    try:
        return json.loads((repo_root / SOURCES_PATH).read_text())
    except (FileNotFoundError, json.JSONDecodeError) as bad:
        return [f"{SOURCES_PATH}: cannot be read ({bad})"]


def pin_errors(repo_root: Path) -> list[str]:
    """DECLARATION -> BUILD: every cited pin file must exist and still pin that
    exact (repo, branch).

    Offline and deterministic, so `check` can run it: it is a plain read of the
    working tree. The pin is PARSED, not searched for — the branch name survives
    in comments, docs and echo lines long after the build stopped using it, so a
    substring scan would call a repoint clean.
    """
    doc = _sources_doc(repo_root)
    if isinstance(doc, list):
        return doc
    errors: list[str] = []
    for fork in doc.get("forks", []):
        repo = fork.get("repo", "?")
        for branch in fork.get("branches", []):
            name = branch.get("name", "?")
            for cited in branch.get("pinnedBy", []):
                target = repo_root / cited
                if not target.exists():
                    errors.append(f"{SOURCES_PATH}: {repo} {name} cites {cited}, which does not exist")
                    continue
                found = pins_in(target, target.read_text(errors="replace"))
                if (repo, name) in found:
                    continue
                actual = ", ".join(f"{r} {b}" for r, b in sorted(found)) or "no fork branch at all"
                errors.append(
                    f"{SOURCES_PATH}: {repo} {name} cites {cited}, but that file pins {actual} — "
                    "the build and the declaration have drifted"
                )
    return errors


def scan_paths(repo_root: Path) -> list[Path]:
    """Every file in the tree that can carry a machine-readable fork pin."""
    found = [repo_root / ".gitmodules"]
    for pattern in SCAN_GLOBS:
        found += sorted(repo_root.glob(pattern))
    return [p for p in found if p.is_file() and not SKIP_DIRS & set(p.relative_to(repo_root).parts)]


def undeclared_pins(repo_root: Path) -> list[str]:
    """BUILD -> DECLARATION: every fork branch the tree actually pins must be
    declared.

    The other direction on its own is a one-way tripwire: a build script that
    starts pinning a branch nobody declared under-reports every later week in
    exactly the silence this module exists to break. A pin on an EXCLUDED branch
    is worse than an undeclared one — the stack is shipping something the
    declaration says visitors never see — so it gets its own message.
    """
    doc = _sources_doc(repo_root)
    if isinstance(doc, list):
        return doc
    shipped, excluded = _declared(doc)
    errors: list[str] = []
    for path in scan_paths(repo_root):
        cited = path.relative_to(repo_root)
        for pin in sorted(pins_in(path, path.read_text(errors="replace"))):
            if pin[0].split("/")[0] != OUR_FORK_OWNER or pin in shipped:
                continue
            if pin in excluded:
                errors.append(
                    f"{cited} pins {pin[0]} {pin[1]}, which {SOURCES_PATH} EXCLUDES "
                    f'("{excluded[pin]}") — the build ships a branch the notes promise it does not'
                )
            else:
                errors.append(
                    f"{cited} pins {pin[0]} {pin[1]}, which {SOURCES_PATH} does not declare — "
                    "declare it under `branches`, or record why it is excluded"
                )
    return errors


def drift_errors(repo_root: Path) -> list[str]:
    """Both directions, which is the whole guarantee `check` advertises."""
    return pin_errors(repo_root) + undeclared_pins(repo_root)
