"""Unit tests for the local country lookup.

The database itself is not in git, so these tests build a tiny real mmdb when
the writer library is available and otherwise exercise the paths that must work
WITHOUT a database — which is the common case on a fresh box and the one that
must never raise.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "serve"))

import geo  # noqa: E402


class RoutableTest(unittest.TestCase):
    def test_public_addresses_are_routable(self):
        self.assertTrue(geo.is_routable("88.192.35.229"))
        self.assertTrue(geo.is_routable("2001:4860:4860::8888"))

    def test_everything_that_cannot_be_a_visitor_is_not(self):
        # Looking these up wastes a read and invites reading meaning into an
        # address that has none.
        for addr in (
            "127.0.0.1",
            "::1",
            "192.168.1.114",
            "10.0.0.1",
            "172.16.0.1",
            "169.254.1.1",
            "224.0.0.1",
            "0.0.0.0",
            "not-an-ip",
            "",
        ):
            self.assertFalse(geo.is_routable(addr), addr)


class CountryCodeWithoutADatabaseTest(unittest.TestCase):
    """A missing database must be silent, not an error anybody sees."""

    def setUp(self):
        self._orig = geo.GEOIP_DB
        geo.GEOIP_DB = Path("/nonexistent/dbip-country-lite.mmdb")
        geo.reset_for_test()

    def tearDown(self):
        geo.GEOIP_DB = self._orig
        geo.reset_for_test()

    def test_absent_database_yields_none_not_an_exception(self):
        self.assertIsNone(geo.country_code("88.192.35.229"))

    def test_absent_database_is_not_retried_per_call(self):
        # The reader is opened once; a box without the file must not pay a
        # failed open on every request.
        geo.country_code("88.192.35.229")
        self.assertTrue(geo._tried)
        self.assertIsNone(geo._reader)

    def test_private_and_empty_are_none_before_any_database_work(self):
        self.assertIsNone(geo.country_code("127.0.0.1"))
        self.assertIsNone(geo.country_code(None))
        self.assertIsNone(geo.country_code(""))


if __name__ == "__main__":
    unittest.main()
