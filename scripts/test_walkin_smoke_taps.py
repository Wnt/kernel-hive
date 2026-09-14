"""The smoke runner must not build onto a LIVE cell's interface name.

`WALKIN_ROOT` namespaces the clone TREE, not the TAP. A smoke run in an empty
sandbox root picks pool index 1, and `wi-<station>-1` is a name in the kernel's
one global namespace — which on a station whose live pool starts at 1 (win311)
is a visitor's cell. Measured as a near-miss on 2026-09-14, during the rhapsody
apple.com bake: rhapsody's pool happens to be numbered 2..9, so the sandbox
build took `wi-rhapsody-1` harmlessly.

THIS FILE LIVES AT scripts/ ON PURPOSE. `scripts/` and `scripts/serve/` are not
packages, and unittest discovery has not descended into non-package directories
since Python 3.11 — so every test under `scripts/serve/**` (the whole auth and
walk-in broker suites included) is invisible to the canonical gate command in
docs/lab/AGENT-CI-EXIT-RULE.md. A test that does not run is not a gate.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
WALKIN = ROOT / "scripts" / "serve" / "walkin"


def _load_smoke():
    """Import smoke.py as part of its package, without needing scripts/ to be one."""
    sys.path.insert(0, str(ROOT / "scripts" / "serve"))
    spec = importlib.util.spec_from_file_location("walkin.smoke", WALKIN / "smoke.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


smoke = _load_smoke()


class FakeNetdev:
    ifname_pattern = "wi-rhapsody-%d"


class FakeSpec:
    station = "rhapsody"
    pool_size = 8
    netdev = FakeNetdev()


class LiveTapNamesTest(unittest.TestCase):
    def _with_interfaces(self, present):
        real = Path.exists

        def fake(self):
            if str(self).startswith("/sys/class/net/"):
                return self.name in present
            return real(self)

        return mock.patch.object(Path, "exists", fake)

    def test_no_interfaces_means_nothing_to_refuse(self):
        with self._with_interfaces(set()):
            self.assertEqual(smoke.live_tap_names(FakeSpec()), [])

    def test_a_live_cell_on_an_index_this_smoke_could_pick_is_named(self):
        # The win311 shape: the live pool holds index 1, which is exactly what a
        # smoke run in an empty sandbox root picks first.
        with self._with_interfaces({"wi-rhapsody-1"}):
            self.assertEqual(smoke.live_tap_names(FakeSpec()), ["wi-rhapsody-1"])

    def test_every_colliding_name_is_reported_not_just_the_first(self):
        with self._with_interfaces({"wi-rhapsody-2", "wi-rhapsody-5"}):
            self.assertEqual(smoke.live_tap_names(FakeSpec()), ["wi-rhapsody-2", "wi-rhapsody-5"])

    def test_it_looks_no_further_than_the_pool_could_reach(self):
        # An interface past pool_size is somebody else's business, not a
        # collision this run could cause.
        with self._with_interfaces({"wi-rhapsody-9"}):
            self.assertEqual(smoke.live_tap_names(FakeSpec()), [])


if __name__ == "__main__":
    unittest.main()
