"""`stations-registry.py new <id> --like <sibling> --production` must scaffold a
station that `validate` immediately accepts, with no render-order collisions.

Runs in a temporary repository containing only registry validation/generation
inputs. The scaffold's generated registry and SPA scene writes therefore stay
in the test copy while normal builds use the real working tree.
"""

from __future__ import annotations

import importlib
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
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
GENERATED_BASE = [
    "registry/generated/labctl-declarations.json",
    "scripts/build-guests/build-all.sh",
    "spa/src/data/posterIndex.ts",
    "spa/src/data/demoPrograms.ts",
    "spa/src/data/keyboards.ts",
    "spa/src/three/archetypeRegistry.ts",
    "streamhost/bring-up-all.sh",
    "streamhost/stations-manifest.sh",
    # `new --like` now inserts the station's two SPA scene rows at its lineup
    # position (scripts/dev/spa-scene-rows.py), so these are restored too.
    "spa/src/scene/assembliesByTile.ts",
    "spa/src/scene/machineIdentity.ts",
    # ...and the rows land in the tables' shards (2026-09-13), so those too.
]

# `new --like` writes many canonical artifacts while its tests run. Keep its
# validation/generation root private so a parallel SPA build never observes a
# half-scaffolded station or half-regenerated scene table. These are the source
# directories read by registry validation/generation; large unrelated trees
# (assets, node_modules, and .git) are deliberately absent.
COPY_DIRS = (
    "registry",
    "scripts/stations_registry",
    "scripts/serve",
    "scripts/build-guests/tiles",
    "scripts/lib",
    "scripts/lint",
    "scripts/retronet/icq",
    "docs",
    "spa/src/scene",
    "streamhost/stations",
    "streamhost/docs",
)
COPY_FILES = (
    "scripts/stations-registry.py",
    "scripts/poster_registry.py",
    "scripts/check-generated-drift.sh",
    "scripts/check-file-size.mjs",
    "scripts/serve/install-public-relay.sh",
    "scripts/dev/spa-scene-rows.py",
    "scripts/dev/box-sync-pairs-selfcheck.sh",
    "streamhost/scripts/streamhost-station.sh",
)

#: distinct from freedos's pizzaBoxB|crtA|keyboardA|paramMouseA — a copied tuple
#: is refused, which is the point of the tuple test below.
TUPLE = "pizzaBoxD,crtF,paramKeyboard,paramMouseG"


def _run(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "scripts/stations-registry.py", *args],
        cwd=repo,
        capture_output=True,
        text=True,
    )


def _make_test_repo(root: Path) -> None:
    """Copy only registry-validation inputs, with empty stand-ins for hero files.

    Registry validation only checks that production hero paths exist; the
    generated gallery manifest uses the paths, never image contents.
    """
    for rel in COPY_DIRS:
        source = REPO / rel
        if source.is_dir():
            shutil.copytree(source, root / rel)
    for rel in COPY_FILES:
        source = REPO / rel
        if source.is_file():
            target = root / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)

    posters = root / "spa/public/posters"
    for station_file in sorted((root / "registry/stations").glob("*.json")):
        row = json.loads(station_file.read_text())
        is_production_stream = (
            row.get("lifecycle") == "production"
            and row.get("enabled")
            and row.get("stream", {}).get("transport") == "streamhost"
        )
        if is_production_stream:
            hero = posters / row["id"] / "desktop.webp"
            hero.parent.mkdir(parents=True, exist_ok=True)
            hero.touch()


def _generated_paths(repo: Path) -> list[str]:
    return [
        *GENERATED_BASE,
        *sorted(
            str(p.relative_to(repo))
            for p in (repo / "spa/src/scene").glob("*.[0-9]*.ts")
            if p.name.startswith(("assembliesByTile.", "machineIdentity."))
        ),
    ]


class NewLikeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory(prefix="stations-registry-new-like-")
        cls.repo = Path(cls._tmp.name)
        _make_test_repo(cls.repo)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmp.cleanup()

    def setUp(self) -> None:
        for rel in CREATED:
            path = self.repo / rel
            if path.exists():
                self.fail(f"pre-existing {rel} would collide with this test; remove it first")
        # Snapshot the exact working-tree bytes of every GENERATED path before the
        # scaffold runs, so tearDown can put back precisely what was here --
        # never `git checkout -- GENERATED`, which resets to the last COMMIT and
        # silently discards any uncommitted regeneration/edit that predates this
        # test (e.g. a wave's own not-yet-committed scene rows). Isolation from
        # the rest of the working tree, not from git history.
        self._generated_snapshot: dict[str, bytes | None] = {}
        for rel in _generated_paths(self.repo):
            path = self.repo / rel
            self._generated_snapshot[rel] = path.read_bytes() if path.exists() else None

    def tearDown(self) -> None:
        for rel in CREATED:
            path = self.repo / rel
            if path.is_dir():
                subprocess.run(["rm", "-rf", str(path)], check=True)
            elif path.exists():
                path.unlink()
        for rel, contents in self._generated_snapshot.items():
            path = self.repo / rel
            if contents is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(contents)

    def test_scaffold_then_validate_is_green_with_no_order_collisions(self) -> None:
        new_result = _run(
            self.repo, "new", NEW_ID, "--like", SIB_ID, "--production", "--slot", "auto", "--tuple", TUPLE
        )
        self.assertEqual(new_result.returncode, 0, new_result.stdout + new_result.stderr)
        self.assertTrue((self.repo / f"registry/stations/{NEW_ID}.json").is_file())
        self.assertTrue((self.repo / f"streamhost/stations/{NEW_ID}/qemu-streamhost.sh").is_file())
        self.assertTrue((self.repo / f"streamhost/stations/{NEW_ID}/station.env.fixture").is_file())

        validate_result = _run(self.repo, "validate")
        self.assertEqual(validate_result.returncode, 0, validate_result.stdout + validate_result.stderr)
        self.assertIn("VALID registry", validate_result.stdout)

        import json

        row = json.loads((self.repo / f"registry/stations/{NEW_ID}.json").read_text())
        sib = json.loads((self.repo / f"registry/stations/{SIB_ID}.json").read_text())
        self.assertEqual(row["lifecycle"], "production")
        self.assertTrue(row["enabled"])
        self.assertEqual(row["id"], NEW_ID)
        self.assertEqual(row["stationDir"], NEW_ID)
        self.assertNotEqual(row["stream"]["slot"], sib["stream"]["slot"])
        self.assertNotEqual(row["runtime"]["bringUpOrder"], sib["runtime"]["bringUpOrder"])
        self.assertNotEqual(row["render"]["bindingOrder"], sib["render"]["bindingOrder"])
        self.assertNotEqual(row["render"]["goldenOrder"], sib["render"]["goldenOrder"])
        self.assertNotEqual(row["render"]["stationsManifestOrder"], sib["render"]["stationsManifestOrder"])
        launcher = (self.repo / f"streamhost/stations/{NEW_ID}/qemu-streamhost.sh").read_text()
        self.assertNotIn(f"streamhost-{SIB_ID}", launcher)
        self.assertIn(f"streamhost-{NEW_ID}", launcher)
        # The two SPA scene rows are part of the scaffold now: without them the
        # entry is a lineup member with no hardware binding, which is exactly
        # the red push every wave of 2026-09-03 discovered at push time.
        # (rows live in the tables' shards since 2026-09-13 — read through the parser)
        package_name = "stations_registry_new_like_isolated"
        spec = importlib.util.spec_from_file_location(
            package_name,
            self.repo / "scripts/stations_registry/__init__.py",
            submodule_search_locations=[str(self.repo / "scripts/stations_registry")],
        )
        assert spec and spec.loader
        package = importlib.util.module_from_spec(spec)
        sys.modules[package_name] = package
        spec.loader.exec_module(package)
        scene = importlib.import_module(f"{package_name}.spa_scene")

        for rel, const in (
            ("spa/src/scene/assembliesByTile.ts", scene.ASSEMBLIES_CONST),
            ("spa/src/scene/machineIdentity.ts", scene.IDENTITY_CONST),
        ):
            self.assertIn(NEW_ID, scene.read_table(rel, const).blocks, rel)
        for name in tuple(sys.modules):
            if name == package_name or name.startswith(package_name + "."):
                del sys.modules[name]

    def test_like_refuses_to_inherit_the_siblings_hardware_tuple(self) -> None:
        refused = _run(self.repo, "new", NEW_ID, "--like", SIB_ID, "--production", "--slot", "auto")
        self.assertEqual(refused.returncode, 1, refused.stdout)
        self.assertIn("would copy its hardware tuple", refused.stderr)
        self.assertIn("--tuple", refused.stderr)
        self.assertFalse((self.repo / f"registry/stations/{NEW_ID}.json").exists())


class LikeRewriteTest(unittest.TestCase):
    """The sibling rewrite must catch the BARE station dir, not only paths under it.

    `operator.labctl.dir` is `/data/vms/streamhost/stations/<id>` with nothing after
    the id. A slash-anchored pattern rewrote `qmp` (`.../<id>/qmp.sock`) and left
    `dir` pointing at the sibling; slackware's station-up found it on 2026-09-03
    (labctl drove tinycore's directory). A longer id that merely starts with the
    sibling's must not be touched.
    """

    def test_bare_station_dir_is_rewritten_and_longer_ids_are_not(self) -> None:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from stations_registry.scaffold_like import _rewrite_like_text

        text = (
            '{"dir": "/data/vms/streamhost/stations/tinycore", '
            '"qmp": "/data/vms/streamhost/stations/tinycore/qmp.sock", '
            '"other": "/data/vms/streamhost/stations/tinycorex/qmp.sock", "id": "tinycore"}'
        )
        out = _rewrite_like_text(text, "tinycore", "slackware")
        self.assertIn('"dir": "/data/vms/streamhost/stations/slackware"', out)
        self.assertIn('"qmp": "/data/vms/streamhost/stations/slackware/qmp.sock"', out)
        self.assertIn('"other": "/data/vms/streamhost/stations/tinycorex/qmp.sock"', out)
        self.assertIn('"id": "slackware"', out)
        self.assertNotIn("stations/tinycore/", out)
        self.assertNotIn('stations/tinycore"', out)


if __name__ == "__main__":
    unittest.main()
