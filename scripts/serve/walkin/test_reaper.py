"""The walk-in plane's KERNEL objects: the orphan sweeps and a clone's plumbing.

    cd scripts && python3 -m unittest serve.walkin.test_reaper

Split out of `test_broker.py` at its line-count cap, and they belong apart: that
file is about who gets a machine and for how long, while everything here is
about taps, cell bridges, and the sweeps that delete them. The seam matters —
on 2026-09-11 those sweeps deleted the tap or cell of a clone that was still
being BUILT, because each acted on a claim snapshot ~2.9 s older than the kernel
state it judged, and a build takes ~3.2 s. Six of twenty-four pool members were
left with no network interface, QEMU alive, still listed free and handed to
visitors for the whole intro budget, because `Clone.alive()` only checks the pid.

So two properties are pinned here, and both fail on the code that shipped:
reading the kernel BEFORE the claim registry, and asking whether a member can
still reach anything at all.
"""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from . import broker as broker_mod
from . import naming
from .test_walkin import REPO


class OrphanTapTests(unittest.TestCase):
    """An orphaned tap fails the next clone at that pool index, not just tidiness."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._real_root = naming.WALKIN_ROOT
        naming.WALKIN_ROOT = Path(self.tmp.name)
        self.addCleanup(self._restore)
        self.broker = broker_mod.Broker(REPO / "does-not-exist", REPO, spawn=False)
        self.downed = []

    def _restore(self):
        naming.WALKIN_ROOT = self._real_root

    def _patch(self, taps, cells=()):
        from . import cell as cell_mod
        from . import claims as claims_mod

        # The sweeps consult the box-wide claim registry; none exists here.
        real_everyone = claims_mod.everyone
        claims_mod.everyone = lambda klass="": []
        self.addCleanup(lambda: setattr(claims_mod, "everyone", real_everyone))

        real_live, real_down = cell_mod.live_taps, cell_mod.tapnet_down  # noqa: F841
        real_cells, real_cell_down = cell_mod.live_cells, cell_mod.cell_down  # noqa: F841
        cell_mod.live_taps = lambda: taps
        cell_mod.tapnet_down = lambda station, tap, bridge="": (self.downed.append((station, tap)), True)[1]
        cell_mod.live_cells = lambda: list(cells)
        cell_mod.cell_down = lambda slot: (self.downed.append(("cell", slot)), True)[1]
        self.addCleanup(lambda: setattr(cell_mod, "live_taps", real_live))
        self.addCleanup(lambda: setattr(cell_mod, "tapnet_down", real_down))
        self.addCleanup(lambda: setattr(cell_mod, "live_cells", real_cells))
        self.addCleanup(lambda: setattr(cell_mod, "cell_down", real_cell_down))

    def test_a_tap_with_no_clone_behind_it_is_taken_down(self):
        self._patch(["wi-os2warp-2", "wi-os2warp-3"])
        self.assertEqual(self.broker.reap_orphan_taps(), ["wi-os2warp-2", "wi-os2warp-3"])
        self.assertEqual(self.downed, [("os2warp", "wi-os2warp-2"), ("os2warp", "wi-os2warp-3")])

    def test_a_tap_recorded_in_a_clone_crumb_is_left_alone(self):
        root = naming.WALKIN_ROOT / "walkin-os2warp-1"
        root.mkdir()
        (root / "clone.json").write_text(json.dumps({"identity": "walkin-os2warp-1", "tap": "wi-os2warp-1"}))
        self._patch(["wi-os2warp-1", "wi-os2warp-2"])
        self.assertEqual(self.broker.reap_orphan_taps(), ["wi-os2warp-2"])

    def test_a_tap_name_recognises_only_the_walk_in_shape(self):
        from . import cell as cell_mod

        self.assertTrue(cell_mod.TAP_RE.match("wi-os2warp-16"))
        for other in ("os2rn0", "win311rn0", "veth952i0", "wi-", "vmbr-wi"):
            self.assertIsNone(cell_mod.TAP_RE.match(other), other)

    def test_a_tap_created_while_the_claim_snapshot_runs_is_not_reaped(self):
        """The 2026-09-11 race, reproduced in the order that caused it.

        Building `known` shells out to the claim registry, which takes ~2.9 s on
        the live box while a clone is built in ~3.2 s. While the kernel was read
        LAST, a tap brought up inside that window was live and unknown, and the
        sweep deleted it out from under a RUNNING guest: six of twenty-four pool
        members were left with no network interface, still listed, still
        claimable, because `alive()` only checks the pid. Reading the kernel
        FIRST makes a late arrival invisible to this tick instead of dead.
        """
        from . import cell as cell_mod
        from . import claims as claims_mod

        live = ["wi-os2warp-2"]
        self._patch(live)
        # A snapshot of the kernel, not a live view — that is what the real
        # `live_taps()` returns, and the distinction is the whole test.
        cell_mod.live_taps = lambda: list(live)
        claims_mod.everyone = lambda klass="": live.append("wi-os2warp-9") or []

        self.assertEqual(self.broker.reap_orphan_taps(), ["wi-os2warp-2"])
        self.assertNotIn(("os2warp", "wi-os2warp-9"), self.downed, "a tap built mid-sweep was destroyed")

    def test_a_cell_created_while_the_claim_snapshot_runs_is_not_reaped(self):
        from . import cell as cell_mod
        from . import claims as claims_mod

        cells = [171]
        self._patch([], cells=cells)
        cell_mod.live_cells = lambda: list(cells)
        claims_mod.everyone = lambda klass="": cells.append(272) or []

        self.assertEqual(self.broker.reap_orphan_cells(), [171])
        self.assertNotIn(("cell", 272), self.downed, "a cell built mid-sweep was destroyed")

    def test_a_cell_with_no_clone_behind_it_is_taken_down(self):
        # A leaked cell blocks its SLOT the way a leaked tap blocks its pool
        # index: `ip link add wibr<slot>` fails and the watchdog re-fails.
        self._patch([], cells=[171, 172])
        self.assertEqual(self.broker.reap_orphan_cells(), [171, 172])
        self.assertEqual(self.downed, [("cell", 171), ("cell", 172)])

    def test_a_cell_recorded_in_a_clone_crumb_is_left_alone(self):
        root = naming.WALKIN_ROOT / "walkin-os2warp-1"
        root.mkdir()
        (root / "clone.json").write_text(json.dumps({"identity": "walkin-os2warp-1", "slot": 171}))
        self._patch([], cells=[171, 172])
        self.assertEqual(self.broker.reap_orphan_cells(), [172])


class CloneNetworkHealthTests(unittest.TestCase):
    """`Clone.alive()` asks whether QEMU is running. This asks whether it can
    reach anything — the question nobody asked until an orphan-sweep race left
    six of twenty-four pool members with no interface, pid healthy, still being
    handed to visitors (2026-09-11)."""

    def setUp(self):
        from . import cell as cell_mod

        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cell = cell_mod
        real = cell_mod.NET_SYSFS
        cell_mod.NET_SYSFS = Path(self.tmp.name)
        self.addCleanup(lambda: setattr(cell_mod, "NET_SYSFS", real))
        self.plan = SimpleNamespace(tap="wi-os2warp-3", slot=258)

    def _up(self, *names):
        for name in names:
            (Path(self.tmp.name) / name).touch()

    def test_both_halves_present_is_healthy(self):
        # The direction that matters most: a check that could only ever answer
        # False would retire the entire pool every tick.
        self._up("wi-os2warp-3", "wibr258")
        self.assertTrue(self.cell.network_present(self.plan))

    def test_a_missing_tap_is_not_healthy(self):
        self._up("wibr258")
        self.assertFalse(self.cell.network_present(self.plan))

    def test_a_missing_cell_is_not_healthy(self):
        self._up("wi-os2warp-3")
        self.assertFalse(self.cell.network_present(self.plan))


class PrimeFailureMessageTests(unittest.TestCase):
    """What a failed prime is allowed to CLAIM.

    One sentence used to cover two different facts, and only one of them was
    true. A member that has lost its tap or cell is EXPECTED and self-correcting
    — the watchdog retires it and the pool rebuilds — so telling an operator
    "the visitor's first page load will fail" on every one of those is the noise
    that hid a real 17-day fault once already. A guest that genuinely did not
    answer is neither expected nor recoverable: measured 2026-09-11, an unprimed
    os2warp emitted zero ARP frames in 500 s and never painted a page.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        real_root = naming.WALKIN_ROOT
        naming.WALKIN_ROOT = Path(self.tmp.name)
        self.addCleanup(lambda: setattr(naming, "WALKIN_ROOT", real_root))

    def _stderr_for(self, missing_half: str) -> str:
        from . import cell as cell_mod

        real = cell_mod.missing_half
        cell_mod.missing_half = lambda plan: missing_half
        self.addCleanup(lambda: setattr(cell_mod, "missing_half", real))

        broker = broker_mod.Broker(REPO / "does-not-exist", REPO, spawn=False)
        broker._spawn, broker._daemon = True, False
        plan = SimpleNamespace(tap="wi-os2warp-3", slot=258, identity="walkin-os2warp-3")
        clone = SimpleNamespace(
            plan=plan,
            identity="walkin-os2warp-3",
            prime_error="wi-clonecell: 10.99.0.19 never answered the cell's gateway ARP in 4s.",
            spawn=lambda: None,
            wait_ready=lambda: "paused",
            prime_network=lambda: False,
        )
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            broker._bring_up(clone)
        return buf.getvalue()

    def test_a_lost_tap_is_reported_as_a_rebuild_not_a_visitor_failure(self):
        out = self._stderr_for("wi-os2warp-3")
        self.assertIn("retiring it for rebuild", out)
        self.assertNotIn("has no network at all", out)
        self.assertIn("wi-clonecell", out, "the helper's own words survive either way")

    def test_a_guest_that_did_not_answer_is_still_reported_loudly(self):
        out = self._stderr_for("")
        self.assertIn("has no network at all", out)
        self.assertNotIn("retiring it for rebuild", out)
        self.assertIn("wi-clonecell", out)
