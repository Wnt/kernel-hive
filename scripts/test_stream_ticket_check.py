#!/usr/bin/env python3
"""The ticket CHECKER must accept what the ticket MINTER actually produces.

WHY THIS EXISTS. `check-stream-tickets.py` re-implements the daemon's
verification so an operator can ask "would this station accept its own
ticket?" without opening a session. That makes it a SECOND implementation of a
format owned by `serve/auth/tickets.py` and `streamhost/src/session_ticket.rs`,
and a second implementation drifts.

It did. When the session trace id started riding the ticket as a query string
(`?traceparent=...`), the minter appended it and the daemon kept splitting it
off before verifying — the HMAC has never covered it. The checker did neither:
it folded the traceparent into the signature and reported `bad signature` for
all 71 stations on a fleet that was streaming perfectly. AGENTS.md sends an
operator to that script when a station will not connect, so the diagnostic
itself became the false alarm.

So these tests do not hand the checker a hand-built string. They mint through
the REAL minter and assert the checker agrees — which is the only shape that
would have caught the drift.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

SERVE = Path(__file__).resolve().parent / "serve"


def _load(name: str, path: Path):
    """Load a single file WITHOUT importing its package.

    `serve/auth/__init__.py` pulls in the passkey stack (fido2), which this
    test neither needs nor should require to check an HMAC; and the checker is
    a hyphenated CLI that has no importable module name at all.
    """
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


tickets = _load("kh_tickets", SERVE / "auth" / "tickets.py")


KEY = b"a-test-stream-ticket-key"


class StreamTicketCheckerTest(unittest.TestCase):
    def setUp(self):
        self.checker = _load("kh_check_stream_tickets", SERVE / "check-stream-tickets.py")

    def test_it_accepts_a_freshly_minted_ticket(self):
        path = tickets.mint(KEY, "win95")
        ok, why = self.checker.verify(KEY, path, "win95")
        self.assertTrue(ok, f"checker rejected a real minted ticket: {why}")

    def test_the_trace_id_query_string_is_not_part_of_the_signature(self):
        """The regression. The minter appends this; the HMAC never covered it."""
        path = tickets.mint(KEY, "win95")
        traced = f"{path}?traceparent=00-50ec780bb0ae2ef526ce985d58384d8b-5fd66537586995e8-01"
        ok, why = self.checker.verify(KEY, traced, "win95")
        self.assertTrue(ok, f"checker rejected a ticket carrying its trace id: {why}")

    def test_a_ticket_signed_for_another_station_is_still_refused(self):
        """Stripping the query must not have loosened the check it exists for."""
        path = tickets.mint(KEY, "solariscde")
        ok, why = self.checker.verify(KEY, path, "solaris")
        self.assertFalse(ok, "a ticket for a different identity must not verify")
        self.assertEqual(why, "bad signature")

    def test_a_tampered_signature_is_refused_even_with_a_query_string(self):
        path = tickets.mint(KEY, "win95")
        exp, nonce, sig = path[len("/wt/") :].split(".")
        forged = f"/wt/{exp}.{nonce}.{'A' * len(sig)}?traceparent=00-{'0' * 32}-{'0' * 16}-01"
        ok, _ = self.checker.verify(KEY, forged, "win95")
        self.assertFalse(ok, "a forged signature must not verify")

    def test_a_non_ticket_path_is_reported_not_crashed(self):
        ok, why = self.checker.verify(KEY, "/not-a-ticket", "win95")
        self.assertFalse(ok)
        self.assertEqual(why, "no ticket in path")


if __name__ == "__main__":
    unittest.main()
