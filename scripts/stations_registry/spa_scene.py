"""The two hand-written SPA scene tables, read and rewritten as ORDERED rows.

`spa/src/scene/assembliesByTile.ts` (ASSEMBLIES_BY_TILE) and
`spa/src/scene/machineIdentity.ts` (EXHIBIT_IDENTITIES) are append-only object
literals with one top-level entry per registry lineup id. Two facts make them
the single worst merge hazard in the repo, and both are asserted by
`spa/src/scene/machines.test.ts`:

  * ORDER. `Object.keys(ASSEMBLIES_BY_TILE)` must equal the registry lineup
    sorted by `order` — key order in a TS object literal is significant, and a
    three-way merge of two waves that each appended a row produces a *clean*
    result in the wrong order.
  * DISTINCTNESS. Every entry needs a distinct `body|monitor|keyboard|mouse`
    signature, so a `new --like` copy that inherits the sibling's tuple fails
    the suite at push time. Nine waves hit exactly that on 2026-09-03.

So a landing must REBUILD these tables from main's copy plus its own row at the
right index — never take the union a merge offers. This module is the parser
and the rebuilder; `scripts/dev/spa-scene-rows.py` is its CLI and
`stations_registry.validate_spa_scene` is the pre-push check.
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .constants import REPO
from .loading import RegistryError, load

ASSEMBLIES_REL = "spa/src/scene/assembliesByTile.ts"
IDENTITY_REL = "spa/src/scene/machineIdentity.ts"
MACHINES_REL = "spa/src/scene/machines.ts"

ASSEMBLIES_CONST = "ASSEMBLIES_BY_TILE"
IDENTITY_CONST = "EXHIBIT_IDENTITIES"

#: the four parts machines.test.ts joins into the uniqueness signature
TUPLE_PARTS = ("body", "monitor", "keyboard", "mouse")

#: ts-src hard cap is 600 (docs/lab/AGENT-CI-EXIT-RULE.md); warn before a wave
#: discovers it mid-landing, the way box-sync-pairs.sh was discovered.
SIZE_WARN_LINES = 560

_ENTRY_RE = re.compile(r"^  ([A-Za-z_][A-Za-z0-9_]*): \{")


@dataclass
class SceneTable:
    """One parsed object-literal table: preamble, ordered blocks, epilogue."""

    path: Path
    const: str
    head: str
    blocks: dict[str, str]
    tail_pending: str
    tail: str

    def label(self) -> str:
        """Repo-relative name where possible; the bare path for a synthetic table."""
        try:
            return str(self.path.relative_to(REPO))
        except ValueError:
            return str(self.path)

    def ids(self) -> list[str]:
        return list(self.blocks)

    def render(self, order: list[str]) -> str:
        missing = [i for i in self.blocks if i not in order]
        if missing:
            raise RegistryError(f"{self.path.name}: rows with no place in the given order: {missing}")
        body = "".join(self.blocks[i] for i in order if i in self.blocks)
        return self.head + body + self.tail_pending + self.tail


def parse_table(text: str, const: str, path: Path) -> SceneTable:
    """Split `export const <const> = { ... } as const satisfies ...` into rows.

    Comment and blank lines immediately above a row belong TO that row (the
    freebsd411 entries each carry a three-line rationale comment), so moving a
    row moves its prose with it.
    """
    lines = text.splitlines(keepends=True)
    open_re = re.compile(rf"^export const {re.escape(const)}\b.*\{{\s*$")
    start = next((i for i, line in enumerate(lines) if open_re.match(line)), None)
    if start is None:
        raise RegistryError(f"{path}: no `export const {const} = {{` line")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("}")), None)
    if end is None:
        raise RegistryError(f"{path}: `{const}` object literal is never closed at column 0")

    head = "".join(lines[: start + 1])
    tail = "".join(lines[end:])
    blocks: dict[str, str] = {}
    pending: list[str] = []
    i = start + 1
    while i < end:
        match = _ENTRY_RE.match(lines[i])
        if match is None:
            pending.append(lines[i])
            i += 1
            continue
        key = match.group(1)
        if key in blocks:
            raise RegistryError(f"{path}: duplicate row {key!r} in {const}")
        depth = 0
        block: list[str] = pending + []
        pending = []
        while i < end:
            depth += lines[i].count("{") - lines[i].count("}")
            block.append(lines[i])
            i += 1
            if depth <= 0:
                break
        blocks[key] = "".join(block)
    return SceneTable(path, const, head, blocks, "".join(pending), tail)


def read_table(rel: str, const: str, *, text: str | None = None) -> SceneTable:
    path = REPO / rel
    if text is None:
        if not path.is_file():
            raise RegistryError(f"{rel}: not in this checkout")
        text = path.read_text(encoding="utf-8")
    return parse_table(text, const, path)


def read_table_at(rel: str, const: str, ref: str) -> SceneTable:
    """The same table as it stands at a git ref — the `rebuild from main` half."""
    try:
        text = subprocess.run(
            ["git", "-C", str(REPO), "show", f"{ref}:{rel}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except subprocess.CalledProcessError as exc:
        raise RegistryError(f"git show {ref}:{rel} failed: {exc.stderr.strip()}") from exc
    return parse_table(text, const, REPO / rel)


def lineup_ids() -> list[str]:
    """Registry lineup ids in the order the SPA scene binds them.

    This is `emit_gallery_manifest`'s selection and sort, spelled out rather
    than reused: `rendered()` calls `validate()`, and this function is called
    FROM `validate()` — going through the emitter is an infinite recursion, not
    a shortcut. The rule it duplicates is one line long and is asserted by
    `scripts/test_spa_scene_rows.py` against the rendered manifest itself, so
    the two cannot drift apart unnoticed.
    """
    _, rows = load()
    selected = [r for r in rows if r.get("enabled") and "bindingOrder" in r.get("render", {})]
    return [r["id"] for r in sorted(selected, key=lambda r: r["render"]["bindingOrder"])]


def model_keys() -> set[str]:
    """Top-level keys of MODELS in machines.ts (what a tuple may name)."""
    return set(read_table(MACHINES_REL, "MODELS").blocks)


def tuple_of(block: str) -> str:
    """The `body|monitor|keyboard|mouse` signature machines.test.ts builds."""
    parts = []
    for part in TUPLE_PARTS:
        match = re.search(rf"\b{part}: '([^']*)'", block)
        parts.append(match.group(1) if match else "none")
    return "|".join(parts)


def duplicate_tuples(table: SceneTable) -> dict[str, list[str]]:
    """signature -> the ids sharing it, for every signature held more than once."""
    seen: dict[str, list[str]] = {}
    for os_id, block in table.blocks.items():
        seen.setdefault(tuple_of(block), []).append(os_id)
    return {sig: ids for sig, ids in seen.items() if len(ids) > 1}


def order_complaint(table: SceneTable, order: list[str]) -> str | None:
    """None when the table's key order IS the lineup order; else what to fix."""
    wanted = [i for i in order if i in table.blocks]
    have = table.ids()
    extra = [i for i in have if i not in order]
    if extra:
        return (
            f"{table.label()}: {table.const} carries row(s) {extra} that are not "
            "registry lineup entries — a lineup entry is the only thing the SPA scene may bind"
        )
    missing = [i for i in order if i not in table.blocks]
    if missing:
        return (
            f"{table.label()}: {table.const} has no row for lineup entry/entries "
            f"{missing}. Add them with `scripts/dev/spa-scene-rows.py <id> --like <sibling> "
            "--tuple body,monitor,keyboard,mouse --apply`"
        )
    if have != wanted:
        first = next(i for i, (a, b) in enumerate(zip(have, wanted, strict=True)) if a != b)
        return (
            f"{table.label()}: {table.const} key order diverges from the registry "
            f"lineup at index {first}: table has {have[first]!r}, lineup has {wanted[first]!r}. "
            "Key order in this literal IS the lineup order machines.test.ts asserts — rebuild the "
            "row with `scripts/dev/spa-scene-rows.py <id> --apply`, never resolve it by hand."
        )
    return None


def free_tuple_suggestions(table: SceneTable, like: str, limit: int = 4) -> list[str]:
    """Tuples near the sibling's that no station holds — a starting point, not advice.

    `new --like` has to refuse an inherited tuple (it is a guaranteed
    machines.test.ts failure), and a refusal that leaves the operator to grep
    machines.ts for a free combination just moves the cost. Vary ONE part of the
    sibling's tuple at a time: the result is a machine that still reads as the
    same era, which is what the exhibit wants, and the human still chooses.
    """
    if like not in table.blocks:
        return []
    taken = {tuple_of(block) for block in table.blocks.values()}
    base = tuple_of(table.blocks[like]).split("|")
    pool: dict[str, list[str]] = {part: [] for part in TUPLE_PARTS}
    for block in table.blocks.values():
        for part, value in zip(TUPLE_PARTS, tuple_of(block).split("|"), strict=True):
            if value != "none" and value not in pool[part]:
                pool[part].append(value)
    out: list[str] = []
    for index, part in enumerate(TUPLE_PARTS):
        for candidate in pool[part]:
            trial = list(base)
            trial[index] = candidate
            signature = "|".join(trial)
            if signature not in taken and signature not in out:
                out.append(signature)
            if len(out) >= limit:
                return out
    return out
