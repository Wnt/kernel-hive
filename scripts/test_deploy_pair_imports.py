"""A deployed module must not import something no pair row deploys.

The original check covered only imports resolving to scripts/lib/, and
explicitly dismissed same-directory siblings because "the pair loops already
carry them as a tree". That holds for scripts/labctl.d/, scripts/serve/auth/,
authui/ and walkin/ — and NOT for top-level scripts/serve/, which is a static
name list. deploy_hint.py landed in that gap on 2026-08-31: imported at module
scope by osgallery-https-server.py with no row of its own, so installing the
importer alone would have stopped the serving plane from starting.
"""

import importlib.util
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("dpi", REPO / "scripts" / "lint" / "deploy-pair-imports.py")
dpi = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dpi)


class SiblingResolution(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.d = Path(self._tmp.name)
        (self.d / "importer.py").write_text("import helper\n")
        (self.d / "helper.py").write_text("x = 1\n")
        (self.d / "pkg").mkdir()
        (self.d / "pkg" / "__init__.py").write_text("")

    def tearDown(self):
        self._tmp.cleanup()

    def test_a_module_sibling_resolves(self):
        got = dpi.resolves_to_sibling(self.d / "importer.py", "helper")
        self.assertEqual(got, self.d / "helper.py")

    def test_a_package_sibling_resolves(self):
        got = dpi.resolves_to_sibling(self.d / "importer.py", "pkg")
        self.assertEqual(got, self.d / "pkg" / "__init__.py")

    def test_stdlib_and_absent_names_do_not_resolve(self):
        for name in ("json", "os", "nosuchthing"):
            self.assertIsNone(dpi.resolves_to_sibling(self.d / "importer.py", name), name)

    def test_a_scripts_lib_importer_is_left_to_the_lib_path(self):
        """Otherwise the lib case would be reported twice, once per rule."""
        self.assertIsNone(dpi.resolves_to_sibling(dpi.LIB / "anything.py", "guest_wake"))


class TheRealRepoIsClean(unittest.TestCase):
    def test_every_deployed_module_has_its_imports_paired(self):
        """Guards both directions the check now covers."""
        self.assertEqual(dpi.main(), 0)

    def test_the_serve_entry_point_and_its_new_sibling_are_both_paired(self):
        paired = dpi.paired_repo_paths(dpi.pairs_text())
        for rel in ("scripts/serve/osgallery-https-server.py", "scripts/serve/deploy_hint.py"):
            self.assertIn(rel, paired, f"{rel} must have a box-sync pair row")


if __name__ == "__main__":
    unittest.main()
