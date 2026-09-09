"""A dark-launch overlay must survive a republish of the runtime documents.

THE INCIDENT. `serve-https-spa.sh publish_manifests` renders serve/tiles.json
and webroot/gallery-manifest.json whole, from the registry — so publishing them
dropped every row a dark launch had added. A dark launch is how a wave shows the
operator an install at /os/<id> before the station is a registry row, so every
landing silently took down every OTHER wave in flight (seven of them on pcbsd's
landing, 2026-09-03), and each of those waves had to notice and re-publish.

The fix has two halves and both are tested here: the declaration now carries the
rows it added, and `darklaunch-station.py reapply` puts them back. These tests
run entirely against a temp serve root — no box, no ssh.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
TOOL = REPO / "scripts/dev/darklaunch-station.py"


def fake_serve(tmp: Path) -> Path:
    serve = tmp / "serve"
    (serve / "webroot").mkdir(parents=True)
    (serve / "darklaunch.d").mkdir()
    (serve / "tiles.json").write_text(json.dumps({"freedos": {"udpPort": 54001, "hashFile": "/x"}}))
    (serve / "webroot/gallery-manifest.json").write_text(
        json.dumps({"schemaVersion": 1, "entries": [{"id": "freedos", "order": 1, "listed": True}]})
    )
    return serve


def fake_rig(tmp: Path, station: str, port: int) -> Path:
    rig = tmp / "rig"
    rig.mkdir()
    (rig / "signaling.json").write_text(json.dumps({"tile": station, "udpPort": port}))
    (rig / "cert_hash_b64.txt").write_text("hash\n")
    return rig


def tool(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True)


class ReapplyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.serve = fake_serve(self.tmp)
        self.rig = fake_rig(self.tmp, "zzrig", 54999)
        published = tool(
            "publish", "zzrig", "--rig", str(self.rig), "--like", "freedos", "--serve-root", str(self.serve)
        )
        self.assertEqual(published.returncode, 0, published.stdout + published.stderr)

    def republish_from_the_registry(self) -> None:
        """What publish_manifests does: rewrite both documents, overlay and all."""
        (self.serve / "tiles.json").write_text(json.dumps({"freedos": {"udpPort": 54001, "hashFile": "/x"}}))
        (self.serve / "webroot/gallery-manifest.json").write_text(
            json.dumps({"schemaVersion": 1, "entries": [{"id": "freedos", "order": 1, "listed": True}]})
        )

    def tiles(self) -> dict:
        return json.loads((self.serve / "tiles.json").read_text())

    def entries(self) -> list[dict]:
        return json.loads((self.serve / "webroot/gallery-manifest.json").read_text())["entries"]

    def test_publish_records_the_rows_it_added_not_just_their_ids(self) -> None:
        decl = json.loads((self.serve / "darklaunch.d/zzrig.json").read_text())
        self.assertEqual(decl["overlay"]["tiles"]["udpPort"], 54999)
        self.assertEqual(decl["overlay"]["entry"]["id"], "zzrig")
        self.assertFalse(decl["overlay"]["entry"]["listed"])
        # verify-box-sync.sh's half of the contract is untouched: it reads
        # `darklaunch` + `files`, and subtracts the declared ids before hashing.
        self.assertEqual(decl["darklaunch"], "zzrig")
        self.assertEqual(len(decl["files"]), 2)
        for spec in decl["files"].values():
            self.assertEqual(spec["ids"], ["zzrig"])

    def test_a_republish_drops_the_overlay_and_reapply_restores_it(self) -> None:
        self.republish_from_the_registry()
        self.assertNotIn("zzrig", self.tiles())
        result = tool("reapply", "--serve-root", str(self.serve))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.tiles()["zzrig"]["udpPort"], 54999)
        self.assertIn("zzrig", [e["id"] for e in self.entries()])
        self.assertIn("re-overlaid 1 station(s): zzrig", result.stdout)

    def test_reapply_is_idempotent(self) -> None:
        """publish_manifests calls it on EVERY publish, so it may never accumulate rows."""
        for _ in range(3):
            tool("reapply", "--serve-root", str(self.serve))
        self.assertEqual([e["id"] for e in self.entries()].count("zzrig"), 1)

    def test_withdraw_then_reapply_does_not_resurrect_the_station(self) -> None:
        tool("withdraw", "zzrig", "--serve-root", str(self.serve))
        tool("reapply", "--serve-root", str(self.serve))
        self.assertNotIn("zzrig", self.tiles())

    def test_a_pre_payload_declaration_warns_loudly_instead_of_claiming_success(self) -> None:
        """Declarations written before this change carry no rows to restore."""
        path = self.serve / "darklaunch.d/zzrig.json"
        decl = json.loads(path.read_text())
        del decl["overlay"]
        path.write_text(json.dumps(decl))
        self.republish_from_the_registry()
        result = tool("reapply", "--serve-root", str(self.serve))
        self.assertEqual(result.returncode, 0)
        self.assertIn("WARNING zzrig has a pre-payload declaration", result.stdout)
        self.assertIn("re-overlaid 0 station(s)", result.stdout)
        self.assertNotIn("zzrig", self.tiles())


class DeployWiringTest(unittest.TestCase):
    """The root fix is only a fix if publish_manifests actually calls it."""

    def test_publish_manifests_reapplies_and_deploy_ships_the_tool(self) -> None:
        text = (REPO / "scripts/serve-https-spa.sh").read_text()
        body = text[text.index("publish_manifests() {") :]
        self.assertIn("reapply_darklaunch", body[: body.index("\n}\n") + 3])
        self.assertIn("cat > $DARKLAUNCH_PY", text)


if __name__ == "__main__":
    unittest.main()
