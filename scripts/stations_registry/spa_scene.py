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
from collections.abc import Callable
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

#: SHARDS. The 600-line cap was reached at 96 stations (2026-09-13, five waves
#: blocked on push at once), so a table is no longer one literal: the index
#: file (`assembliesByTile.ts`) spreads `<CONST>_1`, `<CONST>_2`, … imported
#: from `assembliesByTile.1.ts`, `.2.ts`, … — each shard holding at most
#: SHARD_ROWS rows in lineup order. Key order through object spread is
#: insertion order, so `Object.keys(ASSEMBLIES_BY_TILE)` is still the lineup.
#: Rows live ONLY in shards; the index keeps its hand-written prose and code.
SHARD_ROWS = 40

_ENTRY_RE = re.compile(r"^  ([A-Za-z_][A-Za-z0-9_]*): \{")
_SPREAD_RE = re.compile(r"^  \.\.\.([A-Za-z_][A-Za-z0-9_]*)_(\d+),\s*$")
_SHARD_IMPORT_RE = re.compile(r"^import \{ ([A-Za-z_][A-Za-z0-9_]*)_(\d+) \} from '\./([A-Za-z0-9_]+)\.\2';\s*$")


def shard_rel(rel: str, n: int) -> str:
    """`spa/src/scene/assembliesByTile.ts`, 2 -> `spa/src/scene/assembliesByTile.2.ts`."""
    return rel[: -len(".ts")] + f".{n}.ts"


def shard_count(text: str, const: str) -> int:
    """How many shards an index file spreads (0 = legacy single-literal table)."""
    return sum(1 for line in text.splitlines() if (m := _SPREAD_RE.match(line)) and m.group(1) == const)


@dataclass
class SceneTable:
    """One parsed object-literal table: preamble, ordered blocks, epilogue."""

    path: Path
    const: str
    head: str
    blocks: dict[str, str]
    tail_pending: str
    tail: str
    #: index-file text when the table is sharded (rows come from the shards)
    index_text: str | None = None

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

    def render_files(self, order: list[str], rel: str) -> dict[str, str | None]:
        """The sharded form: {rel: text} for the index and every shard, None = delete.

        Always sharded on write — a legacy single-literal table is converted the
        first time it is rebuilt. The index keeps everything it had except the
        shard import run (regenerated in place, or inserted after the last
        import) and the literal body (replaced by one spread per shard). The
        number of shards follows the row count; a shard that would be empty is
        deleted (None) so `git status` shows the shrink.
        """
        missing = [i for i in self.blocks if i not in order]
        if missing:
            raise RegistryError(f"{self.path.name}: rows with no place in the given order: {missing}")
        ids = [i for i in order if i in self.blocks]
        base = Path(rel).name[: -len(".ts")]
        chunks = [ids[i : i + SHARD_ROWS] for i in range(0, len(ids), SHARD_ROWS)] or [[]]
        out: dict[str, str | None] = {}
        imports = "".join(f"import {{ {self.const}_{n} }} from './{base}.{n}';\n" for n in range(1, len(chunks) + 1))
        spreads = "".join(f"  ...{self.const}_{n},\n" for n in range(1, len(chunks) + 1))
        out[rel] = _render_index(
            self.index_text if self.index_text is not None else self.head + self.tail, self.const, imports, spreads
        )
        for n, chunk in enumerate(chunks, start=1):
            rows = "".join(self.blocks[i] for i in chunk)
            out[shard_rel(rel, n)] = _shard_text(self.const, base, n, len(chunks), rows)
        # surplus shards from a previous, larger layout
        n = len(chunks) + 1
        while (REPO / shard_rel(rel, n)).is_file():
            out[shard_rel(rel, n)] = None
            n += 1
        return out


def _shard_text(const: str, base: str, n: int, total: int, rows: str) -> str:
    type_import = {
        ASSEMBLIES_CONST: "import type { Assembly } from './machines';",
        IDENTITY_CONST: "import type { ExhibitIdentity } from './machineIdentity';",
    }.get(const, "")
    value_type = {ASSEMBLIES_CONST: "Assembly", IDENTITY_CONST: "ExhibitIdentity"}.get(const, "unknown")
    return (
        f"// GENERATED shard {n}/{total} of {const} — rows in registry lineup order, written by\n"
        f"// scripts/dev/spa-scene-rows.py (the index is ./{base}.ts). Edit a ROW here if you must;\n"
        f"// never the layout, and never add a row by hand — the rebuild places it.\n"
        f"{type_import}\n\n"
        f"export const {const}_{n} = {{\n{rows}}} as const satisfies Record<string, {value_type}>;\n"
    )


def _render_index(text: str, const: str, imports: str, spreads: str) -> str:
    lines = text.splitlines(keepends=True)
    kept: list[str] = []
    run_at: int | None = None
    last_import: int | None = None
    for line in lines:
        m = _SHARD_IMPORT_RE.match(line)
        if m and m.group(1) == const:
            if run_at is None:
                run_at = len(kept)
            continue
        if line.startswith("import ") and run_at is None:
            last_import = len(kept)
        kept.append(line)
    if run_at is None:
        run_at = (last_import + 1) if last_import is not None else 0
        kept.insert(run_at, imports)
    else:
        kept.insert(run_at, imports)
    text = "".join(kept)
    open_re = re.compile(rf"^export const {re.escape(const)}\b.*\{{\s*$", re.M)
    m = open_re.search(text)
    if m is None:
        raise RegistryError(f"index for {const}: no `export const {const} = {{` line")
    close = text.find("\n}", m.end() - 1)
    if close < 0:
        raise RegistryError(f"index for {const}: literal never closed at column 0")
    return text[: m.end()] + "\n" + spreads + text[close + 1 :]


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


def _assemble(rel: str, const: str, index_text: str, shard_text: Callable[[str], str]) -> SceneTable:
    """Legacy single literal, or the index + its shards merged into ONE ordered table."""
    path = REPO / rel
    n = shard_count(index_text, const)
    if n == 0:
        return parse_table(index_text, const, path)
    blocks: dict[str, str] = {}
    for k in range(1, n + 1):
        shard = parse_table(shard_text(shard_rel(rel, k)), f"{const}_{k}", REPO / shard_rel(rel, k))
        for key, block in shard.blocks.items():
            if key in blocks:
                raise RegistryError(f"{rel}: row {key!r} appears in more than one shard")
            blocks[key] = block
        if shard.tail_pending.strip():
            raise RegistryError(f"{shard_rel(rel, k)}: stray text after the last row: {shard.tail_pending.strip()!r}")
    table = parse_table(index_text, const, path)
    return SceneTable(path, const, table.head, blocks, "", table.tail, index_text=index_text)


def read_table(rel: str, const: str, *, text: str | None = None) -> SceneTable:
    path = REPO / rel
    if text is not None:
        return parse_table(text, const, path)
    if not path.is_file():
        raise RegistryError(f"{rel}: not in this checkout")

    def shard_text(shard: str) -> str:
        p = REPO / shard
        if not p.is_file():
            raise RegistryError(f"{shard}: the index spreads it but it is not in this checkout")
        return p.read_text(encoding="utf-8")

    return _assemble(rel, const, path.read_text(encoding="utf-8"), shard_text)


def _git_show(ref: str, rel: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(REPO), "show", f"{ref}:{rel}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except subprocess.CalledProcessError as exc:
        raise RegistryError(f"git show {ref}:{rel} failed: {exc.stderr.strip()}") from exc


def read_table_at(rel: str, const: str, ref: str) -> SceneTable:
    """The same table as it stands at a git ref — the `rebuild from main` half."""
    return _assemble(rel, const, _git_show(ref, rel), lambda shard: _git_show(ref, shard))


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
