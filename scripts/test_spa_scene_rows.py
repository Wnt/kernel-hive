"""The SPA scene tables: the parser, the rebuild, and the two validate checks.

These cover the two failures nine waves hit at push time on 2026-09-03 — a
clean-but-wrongly-ordered merge of `assembliesByTile.ts`, and a `--like` copy
that inherited its sibling's hardware tuple. Every case here runs against
synthetic table text, so nothing depends on which stations exist today; the one
test that reads the real tree only asserts that the live files are currently
consistent with the registry, which is what `validate` now enforces.
"""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))

from stations_registry.spa_scene import (  # noqa: E402
    ASSEMBLIES_CONST,
    ASSEMBLIES_REL,
    IDENTITY_CONST,
    IDENTITY_REL,
    duplicate_tuples,
    free_tuple_suggestions,
    lineup_ids,
    order_complaint,
    parse_table,
    read_table,
    tuple_of,
)

TABLE = """import type { Assembly } from './machines';

export const ASSEMBLIES_BY_TILE = {
  alpha: {
    kind: 'pizzaBox', body: 'bodyA', monitor: 'monA',
    keyboard: 'kbA', mouse: 'mouseA',
  },
  // beta carries prose that must travel WITH the row when it moves.
  beta: {
    kind: 'towerSetup', body: 'bodyB', monitor: 'monB',
    keyboard: 'kbB', mouse: 'mouseB',
  },
  gamma: {
    kind: 'combo', combo: 'comboC',
  },
} as const satisfies Record<string, Assembly>;
"""


def table() -> object:
    return parse_table(TABLE, ASSEMBLIES_CONST, Path("assembliesByTile.ts"))


class ParseTest(unittest.TestCase):
    def test_rows_are_read_in_order_with_their_leading_comments(self) -> None:
        parsed = table()
        self.assertEqual(parsed.ids(), ["alpha", "beta", "gamma"])
        self.assertIn("beta carries prose", parsed.blocks["beta"])
        self.assertNotIn("beta carries prose", parsed.blocks["alpha"])

    def test_rendering_the_same_order_is_byte_identical(self) -> None:
        """Idempotence is the whole contract: station-land.sh runs this on every landing."""
        parsed = table()
        self.assertEqual(parsed.render(["alpha", "beta", "gamma"]), TABLE)

    def test_reordering_moves_the_comment_with_its_row(self) -> None:
        out = table().render(["gamma", "beta", "alpha"])
        self.assertLess(out.index("gamma: {"), out.index("beta carries prose"))
        self.assertLess(out.index("beta carries prose"), out.index("beta: {"))
        self.assertEqual(parse_table(out, ASSEMBLIES_CONST, Path("x.ts")).ids(), ["gamma", "beta", "alpha"])

    def test_a_missing_part_reads_as_none_in_the_signature(self) -> None:
        parsed = table()
        self.assertEqual(tuple_of(parsed.blocks["alpha"]), "bodyA|monA|kbA|mouseA")
        self.assertEqual(tuple_of(parsed.blocks["gamma"]), "none|none|none|none")


class OrderAndTupleTest(unittest.TestCase):
    def test_order_complaint_names_the_first_divergent_index(self) -> None:
        parsed = table()
        self.assertIsNone(order_complaint(parsed, ["alpha", "beta", "gamma"]))
        complaint = order_complaint(parsed, ["beta", "alpha", "gamma"])
        self.assertIn("index 0", complaint)
        self.assertIn("spa-scene-rows.py", complaint)

    def test_a_row_that_is_not_a_lineup_entry_is_refused(self) -> None:
        complaint = order_complaint(table(), ["alpha", "beta"])
        self.assertIn("gamma", complaint)
        self.assertIn("not", complaint)

    def test_a_lineup_entry_with_no_row_is_refused(self) -> None:
        complaint = order_complaint(table(), ["alpha", "beta", "gamma", "delta"])
        self.assertIn("delta", complaint)

    def test_a_copied_tuple_is_a_duplicate(self) -> None:
        parsed = table()
        parsed.blocks["delta"] = parsed.blocks["alpha"].replace("alpha:", "delta:")
        dupes = duplicate_tuples(parsed)
        self.assertEqual(list(dupes), ["bodyA|monA|kbA|mouseA"])
        self.assertEqual(sorted(dupes["bodyA|monA|kbA|mouseA"]), ["alpha", "delta"])

    def test_suggestions_vary_one_part_and_are_actually_free(self) -> None:
        parsed = table()
        taken = {tuple_of(block) for block in parsed.blocks.values()}
        for suggestion in free_tuple_suggestions(parsed, "alpha"):
            self.assertNotIn(suggestion, taken)
            differing = sum(
                1 for a, b in zip(suggestion.split("|"), ["bodyA", "monA", "kbA", "mouseA"], strict=True) if a != b
            )
            self.assertEqual(differing, 1, suggestion)


class LiveTreeTest(unittest.TestCase):
    """The real tables, as `stations-registry.py validate` now sees them."""

    def test_lineup_ids_match_the_rendered_gallery_manifest(self) -> None:
        """lineup_ids() re-states emit_gallery_manifest's sort to avoid a recursion.

        That duplication is only safe while the two agree, so prove it against
        the document vitest itself reads rather than trusting the comment.
        """
        emitted = subprocess.run(
            [sys.executable, "scripts/stations-registry.py", "emit", "gallery-manifest.json"],
            cwd=REPO,
            capture_output=True,
            check=True,
        ).stdout
        entries = json.loads(emitted)["entries"]
        self.assertEqual(
            lineup_ids(),
            [e["id"] for e in sorted(entries, key=lambda e: e["order"])],
        )

    def test_both_committed_tables_are_in_lineup_order_and_distinct(self) -> None:
        order = lineup_ids()
        for rel, const in ((ASSEMBLIES_REL, ASSEMBLIES_CONST), (IDENTITY_REL, IDENTITY_CONST)):
            self.assertIsNone(order_complaint(read_table(rel, const), order), rel)
        self.assertEqual(duplicate_tuples(read_table(ASSEMBLIES_REL, ASSEMBLIES_CONST)), {})

    def test_the_cli_check_mode_agrees_with_the_working_tree(self) -> None:
        result = subprocess.run(
            [sys.executable, "scripts/dev/spa-scene-rows.py", lineup_ids()[-1], "--check"],
            cwd=REPO,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
