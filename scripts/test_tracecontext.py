"""Tests for W3C trace-context parsing.

One rule carries all of these: a bad header starts a NEW trace and never fails
the request. Everything below is a way of feeding this parser something a
stranger could put on the wire and checking it answers "no parent" instead of
raising into a request handler.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "serve"))

import tracecontext as tc  # noqa: E402

TRACE = "0af7651916cd43dd8448eb211c80319c"
SPAN = "b7ad6b7169203331"


class ParseTest(unittest.TestCase):
    def test_a_valid_sampled_header(self):
        ctx = tc.parse(f"00-{TRACE}-{SPAN}-01")
        self.assertIsNotNone(ctx)
        self.assertEqual((ctx.trace_id, ctx.span_id, ctx.sampled), (TRACE, SPAN, True))

    def test_the_sampled_flag_is_read_from_the_low_bit(self):
        self.assertFalse(tc.parse(f"00-{TRACE}-{SPAN}-00").sampled)
        self.assertTrue(tc.parse(f"00-{TRACE}-{SPAN}-03").sampled)

    def test_surrounding_whitespace_is_tolerated(self):
        self.assertIsNotNone(tc.parse(f"  00-{TRACE}-{SPAN}-01  "))

    def test_everything_malformed_is_no_parent_and_never_an_exception(self):
        for bad in [
            None,
            "",
            "   ",
            "garbage",
            42,
            [],
            f"00-{TRACE}-{SPAN}",  # too few fields
            f"00-{TRACE}-{SPAN}-01-extra",  # too many
            f"00-{TRACE.upper()}-{SPAN}-01",  # uppercase: spec says lowercase
            f"00-{TRACE[:-1]}-{SPAN}-01",  # short trace id
            f"00-{TRACE}-{SPAN[:-1]}-01",  # short span id
            f"0-{TRACE}-{SPAN}-01",  # short version
            f"00-{TRACE}-{SPAN}-1",  # short flags
            f"00-xyz{TRACE[3:]}-{SPAN}-01",  # non-hex
        ]:
            with self.subTest(bad=repr(bad)[:40]):
                self.assertIsNone(tc.parse(bad))

    def test_the_spec_s_own_invalid_values_are_refused(self):
        # An all-zero id is how the spec spells "invalid", and ff is a forbidden
        # version. Accepting either would attach real work to a null parent.
        self.assertIsNone(tc.parse(f"00-{'0' * 32}-{SPAN}-01"))
        self.assertIsNone(tc.parse(f"00-{TRACE}-{'0' * 16}-01"))
        self.assertIsNone(tc.parse(f"ff-{TRACE}-{SPAN}-01"))

    def test_a_future_version_still_parses(self):
        # The spec requires forward compatibility: a later version must still
        # yield its trace and span ids rather than being discarded wholesale.
        ctx = tc.parse(f"01-{TRACE}-{SPAN}-01")
        self.assertIsNotNone(ctx)
        self.assertEqual(ctx.trace_id, TRACE)


class FormatTest(unittest.TestCase):
    def test_round_trip(self):
        ctx = tc.parse(tc.format(TRACE, SPAN, True))
        self.assertEqual((ctx.trace_id, ctx.span_id, ctx.sampled), (TRACE, SPAN, True))

    def test_unsampled_round_trip(self):
        self.assertFalse(tc.parse(tc.format(TRACE, SPAN, False)).sampled)


class HeaderOfTest(unittest.TestCase):
    def test_reads_the_header_and_survives_a_handler_without_one(self):
        class H:
            headers = {"traceparent": f"00-{TRACE}-{SPAN}-01"}

        class Broken:
            @property
            def headers(self):
                raise RuntimeError("no headers here")

        self.assertIsNotNone(tc.parse(tc.header_of(H())))
        self.assertIsNone(tc.header_of(Broken()))


if __name__ == "__main__":
    unittest.main()
