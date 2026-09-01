"""Stage 4's transactional properties, proven in a temp root.

Every test here is a property the design leans on somewhere else, so each one
names the incident it protects. None of them touches a live path — that is
itself one of the tests.
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "host"))

from kh_reconciler.apply import (  # noqa: E402
    CONFIG_RELOAD,
    MANIFEST_ONLY,
    RECAPTURE,
    RESTART,
    SERVE_RESTART,
    UnitRoot,
    classify,
    classify_member,
    flip,
    materialize,
    resume_needed,
    rollback,
)
from kh_reconciler.denylist import ProtectedPathError  # noqa: E402
from kh_reconciler.store import LiveRootRefused, ObjectStore, refuse_live_root  # noqa: E402


class TheFleetIsOffLimits(unittest.TestCase):
    """Constraint enforced in code, not remembered. There is no override flag."""

    def test_the_live_serving_tree_is_refused(self):
        for p in (
            "/data/vms/streamhost",
            "/data/vms/streamhost/stations/rhapsody",
            "/data/vms/streamhost/serve",
        ):
            with self.assertRaises(LiveRootRefused, msg=p):
                refuse_live_root(Path(p))

    def test_both_entry_points_refuse_it(self):
        with self.assertRaises(LiveRootRefused):
            ObjectStore(Path("/data/vms/streamhost"))
        with self.assertRaises(LiveRootRefused):
            UnitRoot(Path("/data/vms/streamhost"), "station:x")

    def test_a_sandbox_root_is_fine(self):
        with tempfile.TemporaryDirectory() as tmp:
            refuse_live_root(Path(tmp))


class Transaction(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.store = ObjectStore(self.root)
        self.unit = UnitRoot(self.root, "station:test")

    def tearDown(self):
        self._tmp.cleanup()

    def apply(self, members, commit):
        import hashlib

        from kh_reconciler.closure import closure_hash

        closure = closure_hash({p: hashlib.sha256(d).hexdigest() for p, d in members.items()})
        release = materialize(self.unit, self.store, members, closure)
        flip(self.unit, release, closure, commit)
        return closure

    def read(self, name):
        return (self.unit.current / name).read_bytes()

    def test_materialize_touches_nothing_live_until_the_flip(self):
        """A new closure is built BESIDE the running one."""
        first = self.apply({"launcher.sh": b"v1", "tile.env": b"BACKEND=rel"}, "c1")
        import hashlib

        from kh_reconciler.closure import closure_hash

        members = {"launcher.sh": b"v2", "tile.env": b"BACKEND=abs"}
        closure = closure_hash({p: hashlib.sha256(d).hexdigest() for p, d in members.items()})
        materialize(self.unit, self.store, members, closure)
        # Materialized, not flipped: the running set is untouched.
        self.assertEqual(self.unit.applied_hash(), first)
        self.assertEqual(self.read("launcher.sh"), b"v1")
        self.assertEqual(self.read("tile.env"), b"BACKEND=rel")

    def test_the_flip_swaps_the_WHOLE_set_at_once(self):
        """I.3/I.4 become unrepresentable: a new launcher can never meet an old
        binary, because partial application cannot happen."""
        self.apply({"launcher.sh": b"v1", "tile.env": b"BACKEND=rel"}, "c1")
        self.apply({"launcher.sh": b"v2", "tile.env": b"BACKEND=abs"}, "c2")
        self.assertEqual(self.read("launcher.sh"), b"v2")
        self.assertEqual(self.read("tile.env"), b"BACKEND=abs")

    def test_current_always_resolves_across_a_flip(self):
        """rename(2) over the symlink: there is no window where it is missing,
        which matters because a launcher resolves through it."""
        self.apply({"a": b"1"}, "c1")
        self.assertTrue(self.unit.current.is_symlink() and self.unit.current.exists())
        self.apply({"a": b"2"}, "c2")
        self.assertTrue(self.unit.current.is_symlink() and self.unit.current.exists())

    def test_ROLLBACK_IS_COMPLETE_not_field_by_field(self):
        """The sharpest property. Reverting a backend without also restoring the
        cursor scale would leave a station streaming with a silently wrong
        pointer gain and nothing failing. The whole set reverts, or none of it."""
        self.apply({"tile.env": b"BACKEND=rel", "scale.conf": b"2.7778"}, "c1")
        self.apply({"tile.env": b"BACKEND=abs", "scale.conf": b"2.09"}, "c2")
        self.assertEqual(self.read("scale.conf"), b"2.09")
        back = rollback(self.unit)
        self.assertIsNotNone(back)
        self.assertEqual(self.read("tile.env"), b"BACKEND=rel")
        self.assertEqual(self.read("scale.conf"), b"2.7778")  # came back TOO

    def test_rollback_refuses_when_there_is_nowhere_to_go(self):
        """Better than leaving a station with no closure at all."""
        self.apply({"a": b"1"}, "c1")
        self.assertIsNone(rollback(self.unit))
        self.assertEqual(self.read("a"), b"1")  # unchanged

    def test_a_crash_between_materialize_and_flip_is_resumable(self):
        self.unit.record("materialize-begin", closure="sha256:x", members=2)
        self.assertTrue(resume_needed(self.unit))
        self.unit.record("materialize-done", closure="sha256:x")
        self.unit.record("flip-done", closure="sha256:x", commit="c")
        self.assertFalse(resume_needed(self.unit))

    def test_state_of_record_can_never_be_materialized(self):
        with self.assertRaises(ProtectedPathError):
            materialize(self.unit, self.store, {"serve/auth-state.json": b"{}"}, "sha256:x")

    def test_re_applying_the_same_closure_is_a_no_op_on_disk(self):
        c1 = self.apply({"a": b"1"}, "c1")
        target = self.unit.current.resolve()
        c2 = self.apply({"a": b"1"}, "c1")
        self.assertEqual(c1, c2)
        self.assertEqual(self.unit.current.resolve(), target)


class DisruptionClasses(unittest.TestCase):
    def test_a_launcher_change_is_never_automatic(self):
        """golden + binary + device set are ONE combination (rule 6)."""
        self.assertEqual(classify_member("streamhost/stations/beos/qemu-streamhost.sh"), RECAPTURE)
        self.assertEqual(classify_member("streamhost/stations/irix/x11-runtime.sh"), RECAPTURE)

    def test_serve_changes_get_their_own_strictest_class(self):
        """A station restart blinks one exhibit; a serve restart drops every
        active stream fleet-wide and destroys walk-in clones."""
        self.assertEqual(classify_member("scripts/serve/osgallery-https-server.py"), SERVE_RESTART)
        self.assertEqual(classify_member("spa/src/main.tsx"), SERVE_RESTART)

    def test_manifests_are_cheap(self):
        self.assertEqual(classify_member("registry/generated/labctl-declarations.json"), MANIFEST_ONLY)

    def test_fixtures_and_the_daemon_need_a_restart(self):
        self.assertEqual(classify_member("streamhost/stations/beos/tile.env"), RESTART)
        self.assertEqual(classify_member("streamhost/streamhost/src/main.rs"), RESTART)

    def test_the_most_disruptive_member_wins(self):
        mixed = [
            "registry/generated/x.json",
            "streamhost/stations/beos/tile.env",
            "streamhost/stations/beos/qemu-streamhost.sh",
        ]
        self.assertEqual(classify(mixed), RECAPTURE)

    def test_an_empty_diff_is_the_cheapest_class(self):
        self.assertEqual(classify([]), MANIFEST_ONLY)
        self.assertIn(CONFIG_RELOAD, ("config-reload",))


class Store(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.store = ObjectStore(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def test_add_is_idempotent_and_content_addressed(self):
        a = self.store.add_bytes(b"hello")
        b = self.store.add_bytes(b"hello")
        self.assertEqual(a, b)
        self.assertTrue(self.store.has(a))

    def test_verify_detects_corruption(self):
        """A store that cannot detect its own corruption will one day
        materialize corruption confidently."""
        digest = self.store.add_bytes(b"hello")
        self.assertTrue(self.store.verify(digest))
        self.store.path_of(digest).write_bytes(b"tampered")
        self.assertFalse(self.store.verify(digest))

    def test_gc_keeps_everything_a_release_names(self):
        keep = self.store.add_bytes(b"referenced")
        junk = self.store.add_bytes(b"orphan")
        release = Path(self._tmp.name) / "r1"
        release.mkdir()
        (release / "closure.json").write_text(json.dumps({"members": {"a": keep}}))
        removed = self.store.gc([release], dry_run=True)
        self.assertIn(junk, removed)
        self.assertNotIn(keep, removed)

    def test_gc_fails_toward_disk_pressure_not_data_loss(self):
        """An unreadable manifest means UNKNOWN reachability, never zero."""
        self.store.add_bytes(b"x")
        release = Path(self._tmp.name) / "r1"
        release.mkdir()
        (release / "closure.json").write_text("{ not json")
        with self.assertRaises(ValueError):
            self.store.gc([release], dry_run=True)

    def test_materializing_state_of_record_is_refused(self):
        digest = self.store.add_bytes(b"{}")
        with self.assertRaises(ProtectedPathError):
            self.store.materialize(digest, Path(self._tmp.name) / "serve" / "auth-state.json")


class HardlinksMakeReleasesFree(unittest.TestCase):
    def test_two_releases_sharing_a_member_share_the_inode(self):
        """This is what makes keeping the last N closures free, and free
        rollback is the entire point of the closure layout."""
        with tempfile.TemporaryDirectory() as tmp:
            store = ObjectStore(Path(tmp))
            unit = UnitRoot(Path(tmp), "station:t")
            shared = b"unchanged between releases"
            import hashlib

            from kh_reconciler.closure import closure_hash

            for i, other in enumerate([b"v1", b"v2"]):
                members = {"shared.bin": shared, "changing.bin": other}
                c = closure_hash({p: hashlib.sha256(d).hexdigest() for p, d in members.items()})
                r = materialize(unit, store, members, c)
                flip(unit, r, c, f"c{i}")
            releases = [d for d in unit.releases.iterdir() if d.is_dir()]
            self.assertEqual(len(releases), 2)
            inodes = {os.stat(r / "shared.bin").st_ino for r in releases}
            self.assertEqual(len(inodes), 1, "the unchanged member should be one inode")


class RowsCleanIsEnforcedNotRemembered(unittest.TestCase):
    """Stage 3 stated this precondition; stage 4 has to REFUSE on it.

    A reconciler that writes while a third of the fleet's files belong to no
    unit is worse than no reconciler: it reports converged while silently
    owning nothing.
    """

    def setUp(self):
        from kh_reconciler import cli

        self.cli = cli

    def test_unclaimed_rows_refuse_the_write(self):
        from unittest import mock

        rows = [("labctl", "scripts/labctl"), ("mystery", "some/unknown/thing.sh")]
        with (
            mock.patch.object(self.cli, "read_pair_rows", return_value=rows),
            self.assertRaises(self.cli.ApplyRefused) as ctx,
        ):
            self.cli.require_rows_clean(REPO)
        self.assertIn("converged by NOBODY", str(ctx.exception))

    def test_an_unreadable_pair_table_also_refuses(self):
        """An unreadable precondition is not a satisfied one."""
        from unittest import mock

        with (
            mock.patch.object(self.cli, "read_pair_rows", return_value=None),
            self.assertRaises(self.cli.ApplyRefused),
        ):
            self.cli.require_rows_clean(REPO)

    def test_the_real_repo_passes(self):
        self.cli.require_rows_clean(REPO)  # must not raise


if __name__ == "__main__":
    unittest.main()
