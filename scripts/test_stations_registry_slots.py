"""`--slot` must refuse the two reservations that used to be invisible.

Both bit the aix432 add: `--slot auto` handed out a slot belonging to the
walk-in clone pool, and the first slot past that reservation was outside the
edge's relay DNAT window -- a station there streams on the LAN while being
unreachable through the edge, which looks correct and is dead.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from serve.walkin.naming import SLOT_MAX as WALKIN_SLOT_MAX
from serve.walkin.naming import SLOT_MIN as WALKIN_SLOT_MIN
from stations_registry.generate import slot_refusal

GLOBALS = {
    "ports": {
        "productionBase": 54000,
        "publicRelayLow": 54080,
        "publicRelayHigh": 54200,
    }
}


class SlotRefusalTest(unittest.TestCase):
    def test_accepts_a_slot_inside_the_window_and_outside_the_pool(self) -> None:
        self.assertIsNone(slot_refusal(GLOBALS, WALKIN_SLOT_MAX + 1))
        self.assertIsNone(slot_refusal(GLOBALS, 81))

    def test_refuses_the_walkin_reservation_by_name(self) -> None:
        for value in (WALKIN_SLOT_MIN, WALKIN_SLOT_MAX, (WALKIN_SLOT_MIN + WALKIN_SLOT_MAX) // 2):
            refusal = slot_refusal(GLOBALS, value)
            self.assertIsNotNone(refusal, f"slot {value} is the walk-in pool's")
            assert refusal is not None
            self.assertIn("walk-in", refusal)
            # Name the owning module, so the reader can go re-cut it.
            self.assertIn("scripts/serve/walkin/naming.py", refusal)

    def test_refuses_a_slot_whose_udp_port_escapes_the_relay_window(self) -> None:
        # 54000 + 201 = 54201, one past publicRelayHigh.
        refusal = slot_refusal(GLOBALS, 201)
        self.assertIsNotNone(refusal)
        assert refusal is not None
        self.assertIn("54201", refusal)
        self.assertIn("relay window", refusal)

    def test_relay_check_is_skipped_when_the_window_is_undeclared(self) -> None:
        bare = {"ports": {"productionBase": 54000}}
        self.assertIsNone(slot_refusal(bare, 201))


if __name__ == "__main__":
    unittest.main()
