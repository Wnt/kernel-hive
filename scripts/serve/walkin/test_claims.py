"""Slot allocation against the REAL `kh-claim`: python3 -m unittest serve.walkin.test_claims

Mocked out, these tests would have passed while production handed slot 152 to
all three clones at once. The bug lived entirely in what `kh-claim take` MEANS,
so the only test worth writing runs the actual script — it is a shell script in
this repo, it needs nothing but a temp directory, and `KH_CLAIMS_ROOT` points it
somewhere harmless.

The fact under test: `take` is a mutex BETWEEN sessions and idempotent WITHIN
one. The broker is a single `KH_SESSION`, so every clone it builds shares it,
and a zero exit alone never meant "it is mine now".
"""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from . import claims

KH_CLAIM = Path(__file__).resolve().parents[2] / "lib" / "kh-claim.sh"


class SlotClaimTests(unittest.TestCase):
    def setUp(self):
        if not KH_CLAIM.exists():
            self.skipTest("kh-claim.sh is not in this tree")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._env = {k: os.environ.get(k) for k in ("KH_CLAIMS_ROOT", "KH_SESSION", "KH_CLAIM_BIN")}
        self.addCleanup(self._restore)
        os.environ["KH_CLAIMS_ROOT"] = self.tmp.name
        os.environ["KH_SESSION"] = "test-broker"
        os.environ["KH_CLAIM_BIN"] = str(KH_CLAIM)

    def _restore(self):
        for key, value in self._env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_three_clones_of_one_broker_get_three_slots(self):
        """The production bug, in one assertion.

        All three clones are built by ONE broker under ONE KH_SESSION. Before
        the exclusive take, the second and third got `already yours` with a zero
        exit and recorded slot 152 alongside the first — three clones, one claim
        directory, and all three binding UDP 54152.
        """
        held = [claims.claim_slot(f"walkin-os2warp-{n}") for n in (1, 2, 3)]
        self.addCleanup(lambda: [h.release() for h in held])
        slots = [h.slot for h in held]
        self.assertEqual(len(set(slots)), 3, f"duplicate slot handed out: {slots}")
        self.assertEqual(slots, [152, 153, 154])

    def test_the_claim_registry_agrees_with_what_was_handed_out(self):
        held = [claims.claim_slot(f"walkin-os2warp-{n}") for n in (1, 2)]
        self.addCleanup(lambda: [h.release() for h in held])
        recorded = {row["name"] for row in claims.mine(claims.SLOT_CLASS)}
        self.assertEqual(recorded, {"152", "153"})
        ports = {row["name"] for row in claims.mine(claims.PORT_CLASS)}
        self.assertEqual(ports, {"54152", "54153"})

    def test_an_exclusive_take_refuses_a_claim_this_session_already_holds(self):
        first = claims.take(claims.SLOT_CLASS, 152, "clone A", exclusive=True)
        self.addCleanup(first.release)
        with self.assertRaises(claims.ClaimError):
            claims.take(claims.SLOT_CLASS, 152, "clone B", exclusive=True)

    def test_a_non_exclusive_take_is_still_idempotent(self):
        # Everything else on the box relies on re-asserting its own claim, so
        # the default behaviour must not change.
        first = claims.take("sandbox", "mine", "a rig")
        self.addCleanup(first.release)
        claims.take("sandbox", "mine", "the same rig")

    def test_a_released_slot_comes_back(self):
        first = claims.claim_slot("walkin-os2warp-1")
        self.assertEqual(first.slot, 152)
        first.release()
        second = claims.claim_slot("walkin-os2warp-2")
        self.addCleanup(second.release)
        self.assertEqual(second.slot, 152)

    def test_the_pool_ceiling_is_reported_rather_than_wrapped(self):
        held = []
        self.addCleanup(lambda: [h.release() for h in held])
        for n in range(152, 171):
            held.append(claims.claim_slot(f"walkin-os2warp-{n}"))
        with self.assertRaises(claims.ClaimError) as caught:
            claims.claim_slot("walkin-os2warp-one-too-many")
        self.assertIn("152-170", str(caught.exception))

    def test_a_missing_session_is_refused_rather_than_defaulted(self):
        os.environ.pop("KH_SESSION")
        with self.assertRaises(claims.ClaimError):
            claims.claim_slot("walkin-os2warp-1")

    def test_a_uniform_failure_is_reported_as_itself_not_as_a_full_pool(self):
        """The message that cost an afternoon in production.

        With KH_SESSION unset every take failed for that one reason, and the
        loop announced "no free slot in 152-170" against an EMPTY claim class —
        pointing at pool exhaustion when the fault was one missing environment
        variable in the serving unit.
        """
        os.environ.pop("KH_SESSION")
        with self.assertRaises(claims.ClaimError) as caught:
            claims.claim_slot("walkin-os2warp-1")
        message = str(caught.exception)
        self.assertIn("KH_SESSION", message)
        self.assertNotIn("ceiling", message)


if __name__ == "__main__":
    unittest.main()
