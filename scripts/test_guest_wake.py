#!/usr/bin/env python3
"""Tests for the paused-guest honesty contract. Run directly:
`python3 scripts/test_guest_wake.py`.

The property under test is the one the whole change exists for: **a caller can
never have input silently vanish into a paused guest.** Every path here either
delivers to a guest that QEMU agrees is running, or raises `GuestPaused`. There
is no third outcome, and in particular there is no "returned normally, delivered
nothing" — which is exactly what the old best-effort `cont` did.

A fake QMP is the right instrument for this. The real failure is a `cont` that
does not take (another client holds the socket, the monitor is wedged), and
contriving that against a live QEMU is both flaky and slow; what matters is
what the code does when `query-status` keeps saying `running: False`, which is
stated directly here.
"""

from __future__ import annotations

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from guest_wake import (  # noqa: E402
    GuestPaused,
    WakeLease,
    assert_running,
    hold_lease,
    is_running,
    lease_path,
    touch_lease,
    wake,
)


class FakeQmp:
    """A QMP monitor that records what it was asked and can refuse to wake.

    `wakes_on_cont` False models the case the old code could not distinguish
    from success: `cont` is accepted and the vCPUs stay stopped.
    """

    def __init__(self, running: bool = True, wakes_on_cont: bool = True) -> None:
        self.running = running
        self.wakes_on_cont = wakes_on_cont
        self.calls: list[str] = []

    def execute(self, command: str) -> object:
        self.calls.append(command)
        if command == "query-status":
            return {"status": "running" if self.running else "paused", "running": self.running}
        if command == "cont":
            if self.wakes_on_cont:
                self.running = True
            return {}
        raise AssertionError(f"unexpected QMP command {command!r}")


class WakeContract(unittest.TestCase):
    def test_running_guest_costs_one_query_and_no_cont(self):
        """The overwhelmingly common case must stay cheap: a running guest is
        one `query-status`, never a gratuitous `cont`."""
        q = FakeQmp(running=True)
        wake(q.execute)
        self.assertEqual(q.calls, ["query-status"])

    def test_paused_guest_is_resumed_and_verified(self):
        q = FakeQmp(running=False)
        wake(q.execute)
        self.assertIn("cont", q.calls)
        self.assertTrue(q.running)
        # Verified, not assumed: a query-status follows the cont.
        self.assertEqual(q.calls[q.calls.index("cont") + 1], "query-status")

    def test_a_guest_that_will_not_wake_raises_instead_of_returning(self):
        """THE bug, stated as a test. The old code issued `cont`, swallowed
        every failure and returned normally, so the caller went on to inject
        into stopped vCPUs and read the unchanged screen as a wedge."""
        q = FakeQmp(running=False, wakes_on_cont=False)
        with self.assertRaises(GuestPaused) as caught:
            wake(q.execute, "teststation", timeout=0.3)
        msg = str(caught.exception)
        # The error must NAME the state, or it just moves the confusion.
        self.assertIn("teststation", msg)
        self.assertIn("idle-auto-paused", msg)
        self.assertIn("NOTHING was delivered", msg)

    def test_assert_running_catches_a_mid_sequence_refreeze(self):
        """Called AFTER injection: a guest frozen part-way through swallowed an
        unknown part of the sequence, so the screendump that follows is not
        evidence of anything."""
        q = FakeQmp(running=True)
        assert_running(q.execute, "teststation")  # awake: no complaint
        q.running = False
        with self.assertRaises(GuestPaused) as caught:
            assert_running(q.execute, "teststation", "the key sequence")
        self.assertIn("DISCARDED", str(caught.exception))

    def test_is_running_reads_qemus_answer_not_ours(self):
        self.assertTrue(is_running(FakeQmp(running=True).execute))
        self.assertFalse(is_running(FakeQmp(running=False).execute))


class Lease(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.prev = os.environ.get("SH_WAKE_LEASE_DIR")
        # lease_path reads the module-level default, so point the whole module
        # at a temp dir for the duration of the test.
        import guest_wake

        self.mod = guest_wake
        self.saved_dir = guest_wake.LEASE_DIR
        guest_wake.LEASE_DIR = self.tmp.name
        os.environ.pop("SH_WAKE_LEASE", None)

    def tearDown(self):
        self.mod.LEASE_DIR = self.saved_dir
        if self.prev is not None:
            os.environ["SH_WAKE_LEASE_DIR"] = self.prev
        self.tmp.cleanup()

    def test_lease_path_is_derived_from_the_station_name(self):
        """A driver must be able to compute it from the one identifier it always
        has. Must agree with Config::wake_lease in streamhost's config/mod.rs."""
        self.assertEqual(lease_path("win311"), os.path.join(self.tmp.name, "win311.lease"))

    def test_env_override_wins(self):
        os.environ["SH_WAKE_LEASE"] = "/tmp/explicit.lease"
        try:
            self.assertEqual(lease_path("win311"), "/tmp/explicit.lease")
        finally:
            os.environ.pop("SH_WAKE_LEASE")

    def test_touch_creates_and_refreshes(self):
        self.assertTrue(touch_lease("st"))
        p = Path(lease_path("st"))
        self.assertTrue(p.is_file())
        first = p.stat().st_mtime
        time.sleep(0.02)
        touch_lease("st")
        self.assertGreaterEqual(p.stat().st_mtime, first)

    def test_context_manager_holds_then_releases(self):
        with WakeLease("st", refresh=0.02) as lease:
            self.assertTrue(lease.held)
            p = Path(lease_path("st"))
            first = p.stat().st_mtime
            time.sleep(0.1)
            # The refresher thread keeps the mtime moving, which is what stops
            # the daemon's 60 s pause re-assert landing mid-sequence.
            self.assertGreater(p.stat().st_mtime, first)
        # Released: the thread is stopped, so the mtime stops moving and the
        # lease expires on its own. Idle auto-pause is never weakened.
        settled = Path(lease_path("st")).stat().st_mtime
        time.sleep(0.1)
        self.assertEqual(Path(lease_path("st")).stat().st_mtime, settled)

    def test_hold_lease_is_idempotent_per_station(self):
        self.assertIs(hold_lease("st"), hold_lease("st"))

    def test_an_unwritable_lease_dir_does_not_break_the_caller(self):
        """A lease is a nicety; verification is the guarantee. A driver that
        cannot write /run must still be able to drive a guest."""
        self.mod.LEASE_DIR = "/proc/definitely/not/writable"
        self.assertFalse(touch_lease("st"))
        with WakeLease("st") as lease:
            self.assertFalse(lease.held)


if __name__ == "__main__":
    unittest.main(verbosity=2)
