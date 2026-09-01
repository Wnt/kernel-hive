"""The 2026-09-01 data-policy reversal, asserted rather than described.

A series of AI sessions invented privacy, retention and content restrictions
for this plane, wrote them into `traces.py` as enforced limits and into
`docs/ANALYTICS.md` as though the operator had required them, and later sessions
reasoned from them as settled policy. `docs/ANALYTICS.md` §0 is the policy that
replaced them. This file is the executable half of that section: what is now
carried, what is still refused, and WHY for each.

It lives beside `test_traces.py` rather than inside it because that file is at
its size cap — and because "what may this plane carry" is a different question
from "does the store stay consistent", which is what the other file asks.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "serve"))

import traces  # noqa: E402
import traces_otlp  # noqa: E402

T1 = "0af7651916cd43dd8448eb211c80319c"
S1 = "b7ad6b7169203331"


def span(sid, **kw):
    s = {
        "t": T1,
        "s": sid,
        "p": None,
        "n": "station.connect",
        "kd": "internal",
        "st": 1_700_000_000_000,
        "d": 100,
        "h": 0,
        "k": "unset",
    }
    s.update(kw)
    return s


def batch(spans):
    return {"resource": {"session.id": "sess-abc", "kh.class": "human"}, "spans": spans}


class PolicyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = traces.TraceStore(Path(self.tmp.name) / "t.db")

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_a_stacktrace_survives_intake_whole_and_reaches_otlp(self):
        """The 2026-09-01 reversal, asserted end to end. A stack used to be
        refused at intake and clipped by `ATTR_STR_MAX` even if it had not
        been; both were AI-invented rules (docs/ANALYTICS.md §0). A stack that
        arrives truncated is worse than an absent one — it reads as a stack and
        names the wrong frame — so this asserts the BYTES, through the store
        and out of the OTLP export."""
        stack = "\n".join(f"  at frame{i} (bundle.js:{i}:{i})" for i in range(200))
        self.assertGreater(len(stack), traces.ATTR_STR_MAX)
        self.assertLessEqual(len(stack), traces.ATTR_STR_MAX_LONG)
        self.store.record(
            batch([span(S1, a={"exception.stacktrace": stack, "code.stacktrace": stack, "kh.flow": "x"})])
        )
        attrs = self.store.trace(T1)["spans"][0]["attributes"]
        self.assertEqual(attrs["exception.stacktrace"], stack)
        self.assertEqual(attrs["code.stacktrace"], stack)
        self.assertEqual(attrs["kh.flow"], "x")
        exported = traces_otlp.export([self.store.trace(T1)])
        rendered = exported["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["attributes"]
        got = {a["key"]: a["value"] for a in rendered}
        self.assertEqual(got["exception.stacktrace"]["stringValue"], stack)

    def test_identity_and_url_attributes_survive_intake(self):
        """`user.name`, `user.email`, `enduser.id`, `url.full` and `url.query`
        were refused until 2026-09-01. The gallery has named invited accounts
        and pseudonymous walk-in handles and the operator wants both planes to
        carry them; the URL pair is debugging signal."""
        rich = {
            "user.name": "ada",
            "user.email": "ada@example.com",
            "enduser.id": "u-17",
            "enduser.role": "viewer",
            "url.full": "https://example.com/os/beos?tab=2&q=hello",
            "url.query": "tab=2&q=hello",
        }
        self.store.record(batch([span(S1, a=dict(rich))]))
        self.assertEqual(self.store.trace(T1)["spans"][0]["attributes"], rich)

    def test_a_credential_is_refused_by_name_and_by_shape(self):
        """The rule that is NOT a preference. A stored credential is one an
        admin view, a backup or a forwarded OTLP batch can replay, so it never
        enters the store — by explicit name, and by key shape for the name
        nobody thought of."""
        self.store.record(
            batch(
                [
                    span(
                        S1,
                        a={
                            "kh.ticket": "t-abc",
                            "http.request.header.cookie": "sid=1",
                            "kh.auth.token": "deadbeef",
                            "x.password": "hunter2",
                            "some.apiKey": "k",
                            "kh.ticket.kind": "stream",
                            "kh.auth.role": "viewer",
                        },
                    )
                ]
            )
        )
        attrs = self.store.trace(T1)["spans"][0]["attributes"]
        for gone in ("kh.ticket", "http.request.header.cookie", "kh.auth.token", "x.password", "some.apiKey"):
            self.assertNotIn(gone, attrs)
        # ...and the live attribute names that merely LOOK adjacent survive.
        self.assertEqual(attrs["kh.ticket.kind"], "stream")
        self.assertEqual(attrs["kh.auth.role"], "viewer")

    def test_typed_keystroke_content_is_off_until_the_operator_says_otherwise(self):
        """The one item the 2026-09-01 richness pass did NOT decide. Walk-in
        visitors are real third parties; what a stranger types is materially
        different from everything else here. The plumbing exists so the answer
        is one env var, and the default is off."""
        self.assertFalse(traces.TYPED_TEXT_ALLOWED, "KH_TRACE_TYPED_TEXT must default to off")
        self.store.record(batch([span(S1, a={"kh.input.text": "hello", "kh.key.class": "printable"})]))
        attrs = self.store.trace(T1)["spans"][0]["attributes"]
        self.assertNotIn("kh.input.text", attrs)
        # Timing, record type and the coarse key CLASS were never gated by it.
        self.assertEqual(attrs["kh.key.class"], "printable")
        self.assertTrue(all(traces.refused(k) for k in traces.TYPED_TEXT_ATTRS))
