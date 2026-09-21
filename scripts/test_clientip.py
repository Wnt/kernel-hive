"""Unit tests for the X-Forwarded-For trust boundary.

The address this returns is what rate limiting keys on, what the clientlog
stores, and what any geography would resolve. It must be an address some hop
OBSERVED, never one the caller supplied.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

# scripts/serve is not a package, and CI discovers tests only from `scripts`
# (.github/workflows/quality.yml). Same shape as test_serve_return_leg.py.
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "serve"))

from clientip import client_ip  # noqa: E402


class ClientIPTrustBoundaryTest(unittest.TestCase):
    def test_tunnel_peer_is_believed_for_the_edge_written_header(self):
        # The public path arrives as the forwarder agent on loopback, and the
        # edge has already collapsed the header to the address it observed.
        self.assertEqual(client_ip("127.0.0.1", "198.51.100.7"), "198.51.100.7")

    def test_last_entry_wins_if_a_hop_is_ever_appended(self):
        # The edge emits one value today, so first and last agree. Taking the
        # last stays correct if another appending proxy is inserted later.
        self.assertEqual(client_ip("127.0.0.1", "203.0.113.9, 198.51.100.7"), "198.51.100.7")

    def test_direct_caller_cannot_name_itself(self):
        # THE REGRESSION THIS FILE EXISTS FOR. The LAN listener is reachable
        # directly; before 2026-09-21 a caller could assert any address here and
        # have it rate-limited and logged as fact.
        self.assertEqual(client_ip("192.0.2.50", "203.0.113.9"), "192.0.2.50")

    def test_a_spoofed_chain_from_a_direct_caller_is_discarded_entirely(self):
        self.assertEqual(client_ip("192.0.2.50", "203.0.113.9, 198.51.100.7"), "192.0.2.50")

    def test_loopback_without_header_falls_back_to_the_socket(self):
        self.assertEqual(client_ip("127.0.0.1", None), "127.0.0.1")

    def test_ipv6_loopback_is_loopback(self):
        self.assertEqual(client_ip("::1", "198.51.100.7"), "198.51.100.7")

    def test_blank_header_from_the_tunnel_falls_back_to_the_socket(self):
        self.assertEqual(client_ip("127.0.0.1", "   "), "127.0.0.1")

    def test_trailing_comma_does_not_yield_an_empty_attribution(self):
        self.assertEqual(client_ip("127.0.0.1", "198.51.100.7, "), "198.51.100.7")

    def test_no_peer_at_all_is_named_rather_than_guessed(self):
        self.assertEqual(client_ip(None, "198.51.100.7"), "unknown")

    def test_a_garbage_peer_is_not_mistaken_for_loopback(self):
        # is_loopback must fail closed: an unparsable peer is not the tunnel,
        # so the header must not be believed on its behalf.
        self.assertEqual(client_ip("not-an-ip", "203.0.113.9"), "not-an-ip")


if __name__ == "__main__":
    unittest.main()
