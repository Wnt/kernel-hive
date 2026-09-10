"""The wi-tapnet.sh bridge guards, checked against naming.py's window.

Split out of test_walkin.py, which is at the file-size cap — and these belong
apart anyway: everything there exercises Python (spec, derive, device sets),
while this reads three BASH scripts and runs their own case globs.
"""

import subprocess
import unittest
from pathlib import Path

from . import naming

REPO = Path(__file__).resolve().parents[3]


class TapScriptBridgeGuardTest(unittest.TestCase):
    """The per-station wi-tapnet.sh guards must accept exactly the pool's window.

    This is the third place the slot range was written down by hand, and the one
    nobody swept: naming.py and wi-clonecell.sh were both moved to 256-511 while
    these three `assert_bridge` case globs still read `wibr1[5-9][0-9]`. Every
    check passed — the range is Python's business, the guard is bash's — and the
    pool then built nothing at all, refusing its own cells one at a time into a
    log file with `wi-tapnet: refusing bridge 'wibr256'`.

    So the guard is tested against naming.py rather than against a literal: a
    future move of the window fails here instead of on the box.
    """

    STATIONS = ("os2warp", "rhapsody", "win311")

    def _accepts(self, station: str, bridge: str) -> bool:
        """Run the script's own case globs, so the test cannot drift from them."""
        text = (REPO / "streamhost" / "stations" / station / "wi-tapnet.sh").read_text()
        body = text.split("assert_bridge() {", 1)[1].split("esac", 1)[0]
        globs = [
            line.split(")", 1)[0].strip()
            for line in body.splitlines()
            if ") : ;;" in line and not line.strip().startswith("#")
        ]
        self.assertTrue(globs, f"{station}: no accepting globs found in assert_bridge")
        program = 'case "$1" in\n  ' + " | ".join(globs) + ") exit 0 ;;\n  *) exit 1 ;;\nesac\n"
        return subprocess.run(["bash", "-c", program, "_", bridge], check=False).returncode == 0

    def test_every_slot_in_the_window_is_accepted(self):
        for station in self.STATIONS:
            for slot in (naming.SLOT_MIN, naming.SLOT_MIN + 1, 300, 499, naming.SLOT_MAX):
                self.assertTrue(
                    self._accepts(station, f"wibr{slot}"),
                    f"{station}: wibr{slot} is inside {naming.SLOT_MIN}-{naming.SLOT_MAX} and was refused",
                )

    def test_nothing_outside_the_window_is_accepted(self):
        for station in self.STATIONS:
            for slot in (naming.SLOT_MIN - 1, naming.SLOT_MAX + 1, 152, 170, 200):
                self.assertFalse(
                    self._accepts(station, f"wibr{slot}"),
                    f"{station}: wibr{slot} is outside {naming.SLOT_MIN}-{naming.SLOT_MAX} and was accepted",
                )

    def test_the_plane_s_own_bridge_stays_accepted(self):
        for station in self.STATIONS:
            self.assertTrue(self._accepts(station, "vmbr-wi"))

    def test_a_retronet_bridge_is_still_refused(self):
        for station in self.STATIONS:
            self.assertFalse(self._accepts(station, "vmbr-rn"))


if __name__ == "__main__":
    unittest.main()
