"""`stations-registry.py new <id> --like <sibling> --production` must scaffold a
station that `validate` immediately accepts, with no render-order collisions.

Runs against the real registry tree (there is no cheap isolated copy of it) and
cleans up every file it creates, generated outputs included, via `git checkout --`
/ `git clean` scoped to exactly those paths -- never a bare `git clean -f`.
"""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
NEW_ID = "zztestlike"
SIB_ID = "freedos"

CREATED = [
    f"docs/guests/{NEW_ID}.md",
    f"registry/posters/{NEW_ID}.md",
    f"registry/stations/{NEW_ID}.json",
    f"scripts/build-guests/tiles/{NEW_ID}.sh",
    f"scripts/coldboot/{NEW_ID}-bootrec-arm.sh",
    f"spa/public/posters/{NEW_ID}",
    f"streamhost/stations/{NEW_ID}",
]
GENERATED = [
    "registry/generated/labctl-declarations.json",
    "scripts/build-guests/build-all.sh",
    "spa/src/data/posterIndex.ts",
    "spa/src/data/demoPrograms.ts",
    "spa/src/data/keyboards.ts",
    "spa/src/three/archetypeRegistry.ts",
    "streamhost/bring-up-all.sh",
    "streamhost/stations-manifest.sh",
]


def _run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "scripts/stations-registry.py", *args],
        cwd=REPO,
        capture_output=True,
        text=True,
    )


class NewLikeTest(unittest.TestCase):
    def setUp(self) -> None:
        for rel in CREATED:
            path = REPO / rel
            if path.exists():
                self.fail(f"pre-existing {rel} would collide with this test; remove it first")

    def tearDown(self) -> None:
        for rel in CREATED:
            path = REPO / rel
            if path.is_dir():
                subprocess.run(["rm", "-rf", str(path)], check=True)
            elif path.exists():
                path.unlink()
        subprocess.run(["git", "checkout", "--", *GENERATED], cwd=REPO, check=False)

    def test_scaffold_then_validate_is_green_with_no_order_collisions(self) -> None:
        new_result = _run("new", NEW_ID, "--like", SIB_ID, "--production", "--slot", "auto")
        self.assertEqual(new_result.returncode, 0, new_result.stdout + new_result.stderr)
        self.assertTrue((REPO / f"registry/stations/{NEW_ID}.json").is_file())
        self.assertTrue((REPO / f"streamhost/stations/{NEW_ID}/qemu-streamhost.sh").is_file())
        self.assertTrue((REPO / f"streamhost/stations/{NEW_ID}/station.env.fixture").is_file())

        validate_result = _run("validate")
        self.assertEqual(validate_result.returncode, 0, validate_result.stdout + validate_result.stderr)
        self.assertIn("VALID registry", validate_result.stdout)

        import json

        row = json.loads((REPO / f"registry/stations/{NEW_ID}.json").read_text())
        sib = json.loads((REPO / f"registry/stations/{SIB_ID}.json").read_text())
        self.assertEqual(row["lifecycle"], "production")
        self.assertTrue(row["enabled"])
        self.assertEqual(row["id"], NEW_ID)
        self.assertEqual(row["stationDir"], NEW_ID)
        self.assertNotEqual(row["stream"]["slot"], sib["stream"]["slot"])
        self.assertNotEqual(row["runtime"]["bringUpOrder"], sib["runtime"]["bringUpOrder"])
        self.assertNotEqual(row["render"]["bindingOrder"], sib["render"]["bindingOrder"])
        self.assertNotEqual(row["render"]["goldenOrder"], sib["render"]["goldenOrder"])
        self.assertNotEqual(row["render"]["stationsManifestOrder"], sib["render"]["stationsManifestOrder"])
        launcher = (REPO / f"streamhost/stations/{NEW_ID}/qemu-streamhost.sh").read_text()
        self.assertNotIn(f"streamhost-{SIB_ID}", launcher)
        self.assertIn(f"streamhost-{NEW_ID}", launcher)


if __name__ == "__main__":
    unittest.main()
