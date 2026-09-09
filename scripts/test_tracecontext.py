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


class ResponseHeadersTest(unittest.TestCase):
    """The return leg. `traceresponse` is the W3C Level 2 response header and
    is what our own browser plane reads; `Server-Timing: intid;desc=` is the
    token Instana's EUM agent turns into a beacon's `backendTraceId`."""

    def test_both_headers_name_the_same_span(self):
        h = tc.response_headers(TRACE, SPAN)
        self.assertEqual(h["traceresponse"], f"00-{TRACE}-{SPAN}-01")
        self.assertEqual(h["Server-Timing"], f"intid;desc={TRACE}")
        # The response header parses as a trace context by the SAME parser the
        # request leg uses — one opinion about the format, not two.
        parsed = tc.parse(h["traceresponse"])
        self.assertEqual((parsed.trace_id, parsed.span_id), (TRACE, SPAN))

    def test_unsampled_is_carried_through(self):
        self.assertTrue(tc.response_headers(TRACE, SPAN, False)["traceresponse"].endswith("-00"))

    def test_a_noop_span_emits_nothing(self):
        # `tracing.NOOP` has empty ids, which is every untraced route.
        self.assertEqual(tc.response_headers("", ""), {})

    def test_a_malformed_id_emits_nothing_rather_than_a_value_instana_drops(self):
        for trace_id, span_id in (
            (TRACE.upper(), SPAN),
            (TRACE[:-1], SPAN),
            (TRACE, SPAN + "0"),
            (None, SPAN),
            (TRACE, 7),
        ):
            self.assertEqual(tc.response_headers(trace_id, span_id), {}, (trace_id, span_id))


if __name__ == "__main__":
    unittest.main()
