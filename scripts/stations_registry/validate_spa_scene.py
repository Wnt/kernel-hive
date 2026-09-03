"""The two SPA scene tables, checked HERE instead of in somebody's push.

`spa/src/scene/machines.test.ts` already asserts both of these — lineup ORDER
for ASSEMBLIES_BY_TILE, and a distinct `body|monitor|keyboard|mouse` per
station. The problem was never that the failure went unnoticed; it is WHEN it
was noticed. `npx vitest run` needs spa/node_modules and ~30 s, so nine waves
on 2026-09-03 each discovered a bad merge or an inherited tuple at push time,
inside a serialised landing window, with the fleet waiting.

`stations-registry.py validate` runs in under a second with nothing installed,
and it is what `station-land.sh` calls before it pushes. Same two failures, the
same wording as the fix, several minutes earlier — and every message names
`scripts/dev/spa-scene-rows.py`, which repairs both without hand-editing.

The tables are absent in a public clone that has no spa/ checkout only if
somebody deletes them; a missing table is reported, never silently skipped.
"""

from __future__ import annotations

from typing import Any

from .constants import REPO
from .loading import RegistryError
from .spa_scene import (
    ASSEMBLIES_CONST,
    ASSEMBLIES_REL,
    IDENTITY_CONST,
    IDENTITY_REL,
    duplicate_tuples,
    lineup_ids,
    order_complaint,
    read_table,
)

SCENE_TABLES = ((ASSEMBLIES_REL, ASSEMBLIES_CONST), (IDENTITY_REL, IDENTITY_CONST))


def validate_spa_scene(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """(a) lineup order of both scene tables, (b) a distinct hardware tuple each."""
    del rows  # the lineup comes from the RENDERED manifest, the same document vitest reads
    try:
        order = lineup_ids()
    except (RegistryError, KeyError, ValueError) as exc:  # pragma: no cover - render already validated
        errors.append(f"spa scene: cannot render the lineup to check table order against: {exc}")
        return

    for rel, const in SCENE_TABLES:
        if not (REPO / rel).is_file():
            errors.append(f"{rel}: missing — the SPA scene binds every lineup entry in this table")
            continue
        try:
            table = read_table(rel, const)
        except RegistryError as exc:
            errors.append(str(exc))
            continue

        complaint = order_complaint(table, order)
        if complaint:
            errors.append(complaint)

        if const != ASSEMBLIES_CONST:
            continue
        for signature, ids in sorted(duplicate_tuples(table).items()):
            errors.append(
                f"{rel}: stations {sorted(ids)} share the hardware tuple {signature}. Every station "
                "needs a DISTINCT body|monitor|keyboard|mouse (machines.test.ts 'gives every entry a "
                "distinct complete hardware signature') — a `new --like` copy inherits the sibling's "
                "and this is where that shows up. Fix it with `scripts/dev/spa-scene-rows.py "
                "<id> --tuple body,monitor,keyboard,mouse --apply`."
            )
