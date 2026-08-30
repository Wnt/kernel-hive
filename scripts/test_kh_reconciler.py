"""The read-only reconciler's invariants — the ones that must hold before it
is ever allowed to write anything (stage 4).

Two of these are not ordinary unit tests but standing proofs:

* a state-of-record path can never become a closure member, and the mechanism
  RAISES rather than silently dropping;
* every read subcommand writes nothing, proven with an audit hook rather than
  promised in a comment. The 2026-08-24 incident where a dry-run plan
  fast-forwarded the shared checkout — moving every other session's drift
  baseline — is why a read path earns a test.
"""

import io
import os
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "host"))

from kh_reconciler import cli  # noqa: E402
from kh_reconciler.closure import closure_hash  # noqa: E402
from kh_reconciler.denylist import ProtectedPathError, is_protected  # noqa: E402
from kh_reconciler.units import (  # noqa: E402
    build_units,
    station_in_filename,
    unclaimed_live_rows,
    unit_of,
)


class StateOfRecordIsUntouchable(unittest.TestCase):
    """A golden can be recaptured; a passkey cannot."""

    def test_the_account_store_and_its_rotations(self):
        for p in (
            "/data/vms/streamhost/serve/auth-state.json",
            "/data/vms/streamhost/serve/auth-state.json.2026-08-30",
            "/data/vms/streamhost/serve/auth-state.json.bak",
            "serve/auth-state.json",
        ):
            self.assertTrue(is_protected(p), p)

    def test_darklaunch_overlays(self):
        self.assertTrue(is_protected("/data/vms/streamhost/serve/darklaunch.d/rhapsody.json"))
        self.assertTrue(is_protected("serve/darklaunch.d"))

    def test_ordinary_deploy_artifacts_are_not_protected(self):
        for p in ("scripts/serve/osgallery-https-server.py", "spa/src/main.tsx", "serve/index.html"):
            self.assertFalse(is_protected(p), p)

    def test_a_widened_glob_RAISES_rather_than_silently_dropping(self):
        """The mistake must be unrepresentable, not merely discouraged.

        A silent drop would make a widened glob look like it worked — and the
        thing it swallowed would be an account store.
        """
        with self.assertRaises(ProtectedPathError) as ctx:
            build_units(["scripts/serve/x.py", "scripts/serve/darklaunch.d/rhapsody.json"])
        self.assertIn("LIVE STATE OF RECORD", str(ctx.exception))

    def test_the_real_repo_has_no_protected_member(self):
        out = io.StringIO()
        with redirect_stdout(out):
            rc = cli.cmd_denylist(REPO)
        self.assertEqual(rc, 0, out.getvalue())


class UnitsAreDisjointAndSpecific(unittest.TestCase):
    def test_a_stations_own_files_beat_the_broad_globs(self):
        self.assertEqual(unit_of("streamhost/stations/beos/qemu-streamhost.sh"), "station:beos")
        self.assertEqual(unit_of("registry/stations/beos.json"), "station:beos")

    def test_serve_and_host_split(self):
        self.assertEqual(unit_of("scripts/serve/walkin/broker.py"), "serve-code")
        self.assertEqual(unit_of("spa/src/main.tsx"), "serve-code")
        self.assertEqual(unit_of("scripts/lib/kh-claim.sh"), "host-tools")
        self.assertEqual(unit_of("scripts/labctl"), "host-tools")

    def test_manifests_are_their_own_unit(self):
        """Otherwise every station cutover dirties serve and flips it 61 times."""
        self.assertEqual(unit_of("registry/generated/labctl-declarations.json"), "serve-manifests")
        self.assertNotEqual(unit_of("registry/generated/labctl-declarations.json"), "serve-code")

    def test_things_that_ship_with_nothing(self):
        for p in ("docs/lab/x.md", "README.md", "tests/e2e-live/foo.mjs"):
            self.assertIsNone(unit_of(p), p)

    def test_every_member_belongs_to_exactly_one_unit(self):
        units = build_units(["streamhost/stations/beos/launch.sh", "scripts/serve/a.py", "scripts/lib/b.sh"])
        seen = [m for members in units.values() for m in members]
        self.assertEqual(len(seen), len(set(seen)))

    def test_a_deployed_row_no_unit_claims_is_reported(self):
        """Such a row would be converged by nobody, forever."""
        rows = [("labctl", "scripts/labctl"), ("mystery", "some/unknown/thing.sh")]
        self.assertEqual(unclaimed_live_rows(rows), [("mystery", "some/unknown/thing.sh")])


class PerStationFilesOutsideTheStationDirectory(unittest.TestCase):
    """Cross-checking the live pair table left 107 of 349 deployed rows claimed
    by no unit. Every family below came from reading that list, not from
    guessing at the layout — these are regression tests for a decomposition
    that was confidently wrong."""

    STATIONS = frozenset({"sailfishos", "win98se", "win2000", "amiga", "openvms", "solaris", "irix"})

    def u(self, path):
        return unit_of(path, self.STATIONS)

    def test_guest_agents_belong_to_their_station(self):
        self.assertEqual(self.u("streamhost/guest-agents/solaris/cdrv.py"), "station:solaris")

    def test_a_per_station_systemd_dropin(self):
        self.assertEqual(
            self.u("streamhost/deploy/streamhost@openvms.service.d/start-timeout.conf"),
            "station:openvms",
        )

    def test_station_named_as_a_filename_PREFIX(self):
        self.assertEqual(self.u("scripts/retronet/win98se-icq-nudge.py"), "station:win98se")
        self.assertEqual(self.u("scripts/coldboot/amiga-coldboot-watch.sh"), "station:amiga")

    def test_station_named_as_a_filename_SUFFIX(self):
        """The last of the 107, and the reason a prefix rule was not enough."""
        self.assertEqual(self.u("streamhost/deploy/seriald-sailfishos.service"), "station:sailfishos")

    def test_longest_station_id_wins(self):
        """`win2000` must never be read as `win2`."""
        self.assertEqual(station_in_filename("win2000-icq-nudge.py", frozenset({"win2", "win2000"})), "win2000")

    def test_the_daemon_tree_is_one_unit_not_sixty_one(self):
        self.assertEqual(self.u("streamhost/streamhost/src/main.rs"), "streamhost-daemon")
        self.assertEqual(self.u("streamhost/Cargo.lock"), "streamhost-daemon")
        self.assertEqual(self.u("streamhost/deploy/streamhost@.service"), "streamhost-daemon")

    def test_registry_sources_feed_the_manifests_unit(self):
        self.assertEqual(self.u("registry/templates/x.ts.in"), "serve-manifests")
        self.assertEqual(self.u("build/registry/gallery-manifest.json"), "serve-manifests")

    def test_a_station_declaration_still_beats_the_registry_glob(self):
        self.assertEqual(self.u("registry/stations/amiga.json"), "station:amiga")


class ClosureHashing(unittest.TestCase):
    def test_order_independent(self):
        self.assertEqual(closure_hash({"a": "1", "b": "2"}), closure_hash({"b": "2", "a": "1"}))

    def test_a_changed_blob_changes_the_hash(self):
        self.assertNotEqual(closure_hash({"a": "1"}), closure_hash({"a": "2"}))

    def test_ABSENCE_IS_A_CHANGE(self):
        """A digest of contents alone calls a unit converged after a file is
        dropped from it. That is how the boot/ tree was once lost for a week."""
        self.assertNotEqual(closure_hash({"a": "1", "b": "2"}), closure_hash({"a": "1"}))

    def test_a_renamed_member_changes_the_hash(self):
        self.assertNotEqual(closure_hash({"a": "1"}), closure_hash({"b": "1"}))


class ReadPathsNeverWrite(unittest.TestCase):
    """Proven with an audit hook, not promised in a comment."""

    def _no_writes(self, fn):
        writes = []

        def audit(event, args):
            if event == "open" and len(args) > 1:
                flags_or_mode = args[1]
                if (
                    isinstance(flags_or_mode, str)
                    and any(c in flags_or_mode for c in "wxa+")
                    or isinstance(flags_or_mode, int)
                    and flags_or_mode & (os.O_WRONLY | os.O_RDWR)
                ):
                    writes.append((args[0], flags_or_mode))
            if event in ("os.remove", "os.rename", "os.mkdir", "shutil.rmtree"):
                writes.append((event, args))

        sys.addaudithook(audit)
        out = io.StringIO()
        with redirect_stdout(out):
            fn()
        self.assertEqual(writes, [], f"a read path wrote: {writes}")

    def test_units_writes_nothing(self):
        self._no_writes(lambda: cli.cmd_units(REPO, False))

    def test_plan_writes_nothing(self):
        self._no_writes(lambda: cli.cmd_plan(REPO, "HEAD"))

    def test_status_writes_nothing(self):
        self._no_writes(lambda: cli.cmd_status(REPO, "HEAD"))


class LivenessIsHonestWhenNothingHasRun(unittest.TestCase):
    def test_absent_journal_does_not_read_as_converged(self):
        out = io.StringIO()
        with redirect_stdout(out):
            cli.cmd_status(REPO, "HEAD")
        text = out.getvalue()
        self.assertIn("NO LOOP HAS EVER RUN", text)
        self.assertNotIn("converged", text.lower().replace("converges automatically", ""))


if __name__ == "__main__":
    unittest.main()
