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

from serve.walkin import naming as walkin_naming
from stations_registry.generate import slot_refusal
from stations_registry.loading import load as load_registry

GLOBALS = {
    "ports": {
        "productionBase": 54000,
        "publicRelayLow": 54080,
        "publicRelayHigh": 54511,
        "webrtcBridgeUdp": 54200,
    }
}


class SlotRefusalTest(unittest.TestCase):
    def test_accepts_a_slot_inside_the_window_and_outside_the_pool(self) -> None:
        self.assertIsNone(slot_refusal(GLOBALS, 81))
        self.assertIsNone(slot_refusal(GLOBALS, 171))

    def test_the_old_walkin_reservation_is_vacated(self) -> None:
        # 2026-09-10: the pool moved off the low end of the production
        # fleet's own numbering (its old 152-170 reservation, shared with the
        # station lineup) onto its own edge relay window. 152-170 is ordinary
        # production territory again, not a walk-in slot.
        for value in (152, 160, 170):
            self.assertIsNone(slot_refusal(GLOBALS, value))

    def test_production_slots_stop_before_the_walkin_window(self) -> None:
        # The new guard the window move needs: with publicRelayHigh now well
        # past 54255, nothing else would stop `--slot auto` from wandering
        # into the pool's own 256-511 window and handing it to a station.
        self.assertIsNone(slot_refusal(GLOBALS, walkin_naming.SLOT_MIN - 1))
        refusal = slot_refusal(GLOBALS, walkin_naming.SLOT_MIN)
        self.assertIsNotNone(refusal)
        assert refusal is not None
        self.assertIn("walk-in", refusal)

    def test_refuses_the_walkin_reservation_by_name(self) -> None:
        # Contiguous again since the window move (naming.SLOT_MIN..SLOT_MAX,
        # not two bands around the production fleet), so min/max/midpoint all
        # land inside it.
        midpoint = (walkin_naming.SLOT_MIN + walkin_naming.SLOT_MAX) // 2
        for value in (walkin_naming.SLOT_MIN, walkin_naming.SLOT_MAX, midpoint):
            refusal = slot_refusal(GLOBALS, value)
            self.assertIsNotNone(refusal, f"slot {value} is the walk-in pool's")
            assert refusal is not None
            self.assertIn("walk-in", refusal)
            # Name the owning module, so the reader can go re-cut it.
            self.assertIn("scripts/serve/walkin/naming.py", refusal)

    def test_refuses_a_slot_whose_udp_port_escapes_the_relay_window(self) -> None:
        # 54000 + 512 = 54512, one past the widened publicRelayHigh (54511).
        refusal = slot_refusal(GLOBALS, 512)
        self.assertIsNotNone(refusal)
        assert refusal is not None
        self.assertIn("54512", refusal)
        self.assertIn("relay window", refusal)

    def test_refuses_the_webrtc_bridges_ice_port(self) -> None:
        # 54000 + 200 = 54200 is inside the relay window AND the bridge's
        # socket, and well below the walk-in window (256-511) -- the two
        # reservations never overlap.
        refusal = slot_refusal(GLOBALS, 200)
        self.assertIsNotNone(refusal)
        assert refusal is not None
        self.assertIn("54200", refusal)
        self.assertIn("WebRTC bridge", refusal)
        self.assertIn("ports.webrtcBridgeUdp", refusal)
        self.assertIsNone(slot_refusal(GLOBALS, 199))

    def test_relay_check_is_skipped_when_the_window_is_undeclared(self) -> None:
        bare = {"ports": {"productionBase": 54000}}
        self.assertIsNone(slot_refusal(bare, 512))


class WalkinReservationIsDisjointFromTheFleetTest(unittest.TestCase):
    """The regression guard for exactly this bug class.

    2026-09-10: the first attempt to widen the walk-in pool past its old
    152-170 ceiling assumed 152-175 was free. It was not -- 171-175 were five
    live production stations (aix432, amix, ravynos, bootos, pcgeos). The pool
    moved to its own window instead (256-511), but the lesson stands: this
    reads the REAL registry, not a fixture, so a future re-cut that repeats
    that mistake fails the gate instead of colliding with a live station's
    UDP port.
    """

    def test_no_registered_station_sits_inside_the_walkin_reservation(self) -> None:
        _globals_doc, rows = load_registry()
        collisions = {}
        for row in rows:
            slot = row.get("stream", {}).get("slot")
            # Posters and any station mid-scaffold may carry no slot, or an
            # explicit null (scaffold.py's own used_slots discards None for
            # the same reason) -- neither is a claim on this window.
            if isinstance(slot, int) and walkin_naming.SLOT_MIN <= slot <= walkin_naming.SLOT_MAX:
                collisions[row["id"]] = slot
        self.assertEqual(collisions, {}, f"walk-in reservation overlaps live station slot(s): {collisions}")


if __name__ == "__main__":
    unittest.main()
