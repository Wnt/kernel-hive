"""`resetKeepsStream` on the public gallery-manifest, emitted by
`emit_gallery_manifest` (stations_registry/render.py).

D4's reset work (branch `nokia9300-reset`, not merged here) gives a
`resetMode=relaunch` station a control-socket reset that never drops the
guest's WebTransport, once its `station.env.fixture` declares
`SH_RESET_CTL_SOCK`. The SPA's restore flow (useRestoreFlow.ts) needs to know
which stations that is true for, so the derivation lives here: true only when
BOTH `reset.resetMode == "relaunch"` AND the merged fixture env (loading.py's
`_fixtureEnv`, the single source for a station's own env keys) carries
`SH_RESET_CTL_SOCK`. No new registry input field — this is computed, exactly
like `relativePointerOnly` a few lines below it in the same function, and
omitted (not emitted false) whenever it does not hold, same convention as the
rest of the block.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stations_registry.render import emit_gallery_manifest  # noqa: E402


def _row(**overrides: object) -> dict:
    row = {
        "id": "nokia9300",
        "era_year": 2005,
        "enabled": True,
        "museum": {
            "displayName": "Nokia 9300",
            "year": 2005,
            "lineage": "Nokia 9300",
            "arch": "ARM925T",
            "accent": "#5B7FA6",
        },
        "spa": {
            "archetypeId": "putty-lcd",
            "transport": "streamhost",
            "eraLabel": "2005 · Series 80 v2",
        },
        "render": {"bindingOrder": 1},
        "reset": {"resetMode": "relaunch"},
    }
    row.update(overrides)
    return row


def _entries(rows: list[dict]) -> list[dict]:
    return json.loads(emit_gallery_manifest(rows))["entries"]


class ResetKeepsStreamTest(unittest.TestCase):
    def test_true_only_with_relaunch_and_the_fixture_socket(self) -> None:
        row = _row(_fixtureEnv={"SH_RESET_CTL_SOCK": "work/run/ekactl.sock"})
        entries = _entries([row])
        self.assertTrue(entries[0]["resetKeepsStream"])

    def test_omitted_without_the_fixture_key(self) -> None:
        row = _row(_fixtureEnv={"SH_IDLE_PAUSE_SECS": "60"})
        entries = _entries([row])
        self.assertNotIn("resetKeepsStream", entries[0])

    def test_omitted_without_any_fixture_env_at_all(self) -> None:
        # Today's nokia9300.json on this branch — the pre-D4 fixture has no
        # SH_RESET_CTL_SOCK, so the field must not appear until that branch's
        # fixture change lands. This is the regression this test pins.
        entries = _entries([_row()])
        self.assertNotIn("resetKeepsStream", entries[0])

    def test_omitted_when_resetMode_is_not_relaunch(self) -> None:
        # The control-socket reset is a `relaunch` mechanism specifically — a
        # `loadvm`/`restart`/`pve-rollback` station never gets this field even
        # if its fixture happens to carry the same key name for something else.
        row = _row(
            reset={"resetMode": "loadvm"},
            _fixtureEnv={"SH_RESET_CTL_SOCK": "work/run/ekactl.sock"},
        )
        entries = _entries([row])
        self.assertNotIn("resetKeepsStream", entries[0])

    def test_omitted_for_a_poster_row_with_no_reset_block(self) -> None:
        row = _row(_fixtureEnv={"SH_RESET_CTL_SOCK": "work/run/ekactl.sock"})
        del row["reset"]
        entries = _entries([row])
        self.assertNotIn("resetKeepsStream", entries[0])


if __name__ == "__main__":
    unittest.main()
