#!/usr/bin/env python3
"""spa-scene-rows.py — put ONE station's rows into the two SPA scene tables,
at its registry lineup position, by REBUILDING the tables. Never a union.

    scripts/dev/spa-scene-rows.py <id>                     plan (default)
    scripts/dev/spa-scene-rows.py <id> --apply             write
    scripts/dev/spa-scene-rows.py <id> --check             exit 1 if a rebuild
                                                           would change anything
    scripts/dev/spa-scene-rows.py <id> --like reactos \\
        --tuple towerC,crtD,keyboardA,paramMouseC --apply  create the rows

WHY THIS EXISTS. `spa/src/scene/assembliesByTile.ts` and
`spa/src/scene/machineIdentity.ts` are append-only object literals whose KEY
ORDER is the registry lineup order — `spa/src/scene/machines.test.ts` asserts
`Object.keys(ASSEMBLIES_BY_TILE)` equals the lineup sorted by `order`, and that
every entry has a distinct `body|monitor|keyboard|mouse` signature. Two waves
that each append a row merge *cleanly* into the wrong order, and a
`new --like` copy silently inherits the sibling's tuple. Both failures surface
only at push time, in vitest, inside somebody's landing window; nine waves paid
for them on 2026-09-03.

So a landing does not merge these files, it rebuilds them: take main's table,
insert this station's row at its lineup index, write. That is idempotent by
construction — running it twice produces the same bytes — which is what makes
it safe to put in `scripts/dev/station-land.sh` and in the `--like` scaffold.

    --base-ref REF   rebuild on top of REF's copy of the tables instead of the
                     working tree's (the landing form: `--base-ref origin/main`
                     discards whatever a three-way merge produced locally and
                     keeps only THIS station's row).
    --like SIBLING   when the station has no row yet, copy SIBLING's, which is
                     the only template that is guaranteed to type-check.
    --tuple B,M,K,Mo overwrite body,monitor,keyboard,mouse (use `none` to omit a
                     part). Required with --like: an inherited tuple is a
                     guaranteed test failure.
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from stations_registry.constants import REPO  # noqa: E402
from stations_registry.loading import RegistryError  # noqa: E402
from stations_registry.spa_scene import (  # noqa: E402
    ASSEMBLIES_CONST,
    ASSEMBLIES_REL,
    IDENTITY_CONST,
    IDENTITY_REL,
    SIZE_WARN_LINES,
    TUPLE_PARTS,
    SceneTable,
    duplicate_tuples,
    lineup_ids,
    model_keys,
    read_table,
    read_table_at,
    tuple_of,
)

TABLES = ((ASSEMBLIES_REL, ASSEMBLIES_CONST), (IDENTITY_REL, IDENTITY_CONST))


def rename_block(block: str, old: str, new: str) -> str:
    """Re-key a copied row and drop the comment prose that described the sibling."""
    lines = [line for line in block.splitlines(keepends=True) if not line.lstrip().startswith("//")]
    lines = [line for line in lines if line.strip()]
    text = "".join(lines)
    return re.sub(rf"^  {re.escape(old)}: \{{", f"  {new}: {{", text, count=1)


def apply_tuple(block: str, parts: dict[str, str]) -> str:
    """Overwrite body/monitor/keyboard/mouse in an assembly row; `none` removes."""
    for part, value in parts.items():
        pattern = rf"\b{part}: '[^']*',?\s*"
        if value == "none":
            block = re.sub(pattern, "", block)
            continue
        if re.search(rf"\b{part}: '[^']*'", block):
            block = re.sub(rf"\b{part}: '[^']*'", f"{part}: '{value}'", block)
        else:
            block = re.sub(r"(\n  \},)", f"\n    {part}: '{value}',\\1", block, count=1)
    # The removals above can leave a line holding nothing but whitespace.
    return "".join(line for line in block.splitlines(keepends=True) if line.strip())


def source_row(rel: str, const: str, os_id: str, like: str | None) -> str:
    """This station's existing row, or a copy of the sibling's, keyed to it."""
    table = read_table(rel, const)
    if os_id in table.blocks:
        return table.blocks[os_id]
    if like is None:
        raise RegistryError(
            f"{rel}: no row for {os_id!r} and no --like SIBLING to copy one from. "
            "A row has to come from somewhere that type-checks; pick the closest station."
        )
    if like not in table.blocks:
        raise RegistryError(f"{rel}: --like sibling {like!r} has no row either")
    block = rename_block(table.blocks[like], like, os_id)
    if const == IDENTITY_CONST:
        block = f"  // TODO({os_id}): exhibit finish copied from {like} — set the real era cues.\n" + block
    return block


def rebuilt(rel: str, const: str, os_id: str, row: str, order: list[str], base_ref: str | None) -> SceneTable:
    base = read_table_at(rel, const, base_ref) if base_ref else read_table(rel, const)
    base.blocks[os_id] = row
    return base


def report(path: Path, before: str, after: str, apply: bool) -> bool:
    """Print the change; return True when the file is (or would be) modified."""
    rel = path.relative_to(REPO)
    if before == after:
        print(f"  {rel}: unchanged")
        return False
    diff = difflib.unified_diff(
        before.splitlines(keepends=True), after.splitlines(keepends=True), f"a/{rel}", f"b/{rel}"
    )
    sys.stdout.writelines(diff)
    lines = after.count("\n")
    if lines >= SIZE_WARN_LINES:
        print(
            f"  NOTE {rel} is now {lines} lines against a 600-line ts-src hard cap "
            "— split the table before the next wave lands, not during one."
        )
    if apply:
        path.write_text(after, encoding="utf-8")
        print(f"  wrote {rel}")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("id")
    ap.add_argument("--like", help="sibling station id to copy a missing row from")
    ap.add_argument("--tuple", dest="tuple_arg", help="body,monitor,keyboard,mouse (`none` omits a part)")
    ap.add_argument("--base-ref", help="rebuild on top of this ref's tables (e.g. origin/main)")
    ap.add_argument("--apply", action="store_true", help="write the rebuilt tables")
    ap.add_argument("--check", action="store_true", help="exit 1 if a rebuild would change anything")
    args = ap.parse_args()

    order = lineup_ids()
    if args.id not in order:
        raise RegistryError(
            f"{args.id!r} is not a registry lineup entry — the SPA scene binds lineup entries only. "
            "Scaffold and enable the registry row first (`stations-registry.py new`)."
        )
    parts: dict[str, str] = {}
    if args.tuple_arg:
        values = [v.strip() for v in args.tuple_arg.split(",")]
        if len(values) != len(TUPLE_PARTS):
            raise RegistryError(f"--tuple needs {len(TUPLE_PARTS)} comma-separated parts: {','.join(TUPLE_PARTS)}")
        known = model_keys()
        unknown = sorted(v for v in values if v != "none" and v not in known)
        if unknown:
            raise RegistryError(f"--tuple names model key(s) machines.ts does not declare: {unknown}")
        parts = dict(zip(TUPLE_PARTS, values, strict=True))

    print(f"spa-scene-rows {args.id}: lineup index {order.index(args.id)} of {len(order)}")
    changed = False
    for rel, const in TABLES:
        row = source_row(rel, const, args.id, args.like)
        if parts and const == ASSEMBLIES_CONST:
            row = apply_tuple(row, parts)
        table = rebuilt(rel, const, args.id, row, order, args.base_ref)
        if const == ASSEMBLIES_CONST:
            clashes = {sig: ids for sig, ids in duplicate_tuples(table).items() if args.id in ids}
            if clashes:
                sig, ids = next(iter(clashes.items()))
                raise RegistryError(
                    f"hardware tuple {sig} is shared by {sorted(ids)}. machines.test.ts requires a "
                    "DISTINCT body|monitor|keyboard|mouse per station — pass --tuple with parts this "
                    f"station actually had ({tuple_of(row)} is the copy)."
                )
        after = table.render(order)
        path = REPO / rel
        before = path.read_text(encoding="utf-8") if path.is_file() else ""
        changed |= report(path, before, after, args.apply)

    if args.check and changed:
        print("spa-scene-rows: --check FAILED (rebuild differs from the working tree)", file=sys.stderr)
        return 1
    if not args.apply and not args.check and changed:
        print("spa-scene-rows: plan only — re-run with --apply to write")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RegistryError as exc:
        print(f"spa-scene-rows: ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
