"""Does the input-path trace vocabulary survive our OWN intake?

The failure this exists to prevent has happened here before: a span family was
emitted, `/traces` silently refused it, and the report read zero — which looks
exactly like "the feature is not used" (`test_stream_event_intake.py`'s
docstring tells that story). The input path just grew a transport hop with a
dozen semantic-convention attributes and two new span names, so the same guard
now covers it.

It reads the REAL names out of the REAL sources — the SPA modules that emit
them and the Rust module that emits the daemon half — and runs them through the
REAL server-side validators in `scripts/serve/traces.py`, never against a copy
of the rules. An extraction that finds nothing FAILS here rather than passing
quietly.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "serve"))

import traces  # noqa: E402

SPA = ROOT / "spa" / "src" / "three" / "streamClient"
RUST = ROOT / "streamhost" / "streamhost" / "src"

#: Modules that name a span on the input path, browser side.
SPAN_SOURCES = (
    SPA / "inputTrace.ts",
    SPA / "inputWire.ts",
    SPA / "frameTrace.ts",
)
#: The daemon's half. `Span::child("name", ...)` and `emit_at("name", ...)`.
RUST_SPAN_SOURCES = (
    RUST / "trace_session.rs",
)
#: The one module that builds the transport hop's attribute set.
ATTR_SOURCE = SPA / "transportFacts.ts"

#: Span names emitted on the input path, in both processes. Written out rather
#: than only extracted so a REMOVED span is a test failure too — an extractor
#: alone cannot notice something that stopped being emitted.
EXPECTED_SPANS = {
    "input.edge",
    "input.wire",
    "input.dispatch",
    "client.input.roundtrip",
    "client.frame.receive",
    "client.frame.decode",
    "client.frame.paint",
    "guest.frame.next",
    "transport.frame.next",
}

_TS_SPAN = re.compile(r"""(?:emitSpan\(\s*[^,]+,\s*[^,]+,\s*|\.child\(\s*)['"]([a-zA-Z][\w.\-]*)['"]""")
_TS_LITERAL_SPAN = re.compile(r"""['"](input\.(?:edge|wire)|client\.[\w.]+)['"]""")
_RS_SPAN = re.compile(r"""(?:Span::child|emit_at)\(\s*\n?\s*"([a-zA-Z][\w.\-]*)\"""")
_ATTR_KEY = re.compile(r"""^\s*(?:a\[)?['"]([a-z][\w.]*)['"]\s*[\]:]\s*[:=]?""", re.M)


def _read(path: Path) -> str:
    if not path.exists():  # pragma: no cover - a moved file must fail loudly
        raise AssertionError(f"source disappeared: {path}")
    return path.read_text(encoding="utf-8")


def emitted_span_names() -> set[str]:
    names: set[str] = set()
    for p in SPAN_SOURCES:
        text = _read(p)
        names |= set(_TS_SPAN.findall(text))
        names |= set(_TS_LITERAL_SPAN.findall(text))
    for p in RUST_SPAN_SOURCES:
        names |= set(_RS_SPAN.findall(_read(p)))
    return names


def transport_attr_keys() -> set[str]:
    """Every attribute key `transportAttrs` can put on an `input.wire` span."""
    text = _read(ATTR_SOURCE)
    start = text.index("export function transportAttrs")
    body = text[start:]
    keys = set(re.findall(r"""a\[['"]([\w.]+)['"]\]\s*=""", body))
    keys |= set(re.findall(r"""^\s*['"]([\w.]+)['"]:\s""", body, re.M))
    return keys


class SpanNamesSurviveIntake(unittest.TestCase):
    def test_extraction_found_something(self):
        self.assertTrue(emitted_span_names(), "extractor found no span names at all")

    def test_every_expected_span_is_still_emitted(self):
        missing = EXPECTED_SPANS - emitted_span_names()
        self.assertEqual(set(), missing, f"input-path spans no longer emitted: {sorted(missing)}")

    def test_every_emitted_name_matches_the_intake_pattern(self):
        for name in sorted(emitted_span_names() | EXPECTED_SPANS):
            with self.subTest(name=name):
                self.assertIsNotNone(
                    traces.NAME_RE.match(name),
                    f"span name {name!r} would be refused by /traces",
                )


class TransportAttrsSurviveIntake(unittest.TestCase):
    #: The fullest form `transportAttrs` ever returns: every optional key
    #: present at once. Values are scrubbed placeholders (AGENTS.md rule 1) —
    #: the real ones are read from the signalling document at runtime and are
    #: never committed anywhere.
    FULL = {
        "network.transport": "quic",
        "network.protocol.name": "http",
        "network.protocol.version": "3",
        "peer.service": "kernel-hive-daemon",
        "kh.wire.reliability": "stream",
        "kh.transport": "webtransport",
        "kh.transport.conn": "0123456789abcdef",
        "server.address": "labhost",
        "server.port": 8443,
        "net.peer.name": "labhost",
        "net.peer.port": 8443,
        "kh.transport.rtt_ms": 7.5,
        "kh.transport.rtt_min_ms": 6.0,
        "kh.transport.dgram_lost": 2,
        "kh.input.class": "key",
        "kh.station.id": "win95",
    }

    def test_the_extractor_agrees_with_the_declared_set(self):
        """Every key the module can emit is one this test actually exercises.

        Without this, a key added to `transportFacts.ts` would sail past the
        intake check below because the check only ever saw the old set."""
        extracted = transport_attr_keys()
        self.assertTrue(extracted, "extractor found no attribute keys")
        # `kh.transport.stats` is the absence marker, mutually exclusive with
        # the RTT keys — never present in the fullest form.
        unknown = extracted - set(self.FULL) - {"kh.transport.stats"}
        self.assertEqual(set(), unknown, f"untested transport attributes: {sorted(unknown)}")

    def test_nothing_is_banned_at_intake(self):
        self.assertEqual(set(), set(self.FULL) & traces.BANNED_ATTRS)

    def test_the_fullest_set_survives_clean_attrs_intact(self):
        cleaned = traces._clean_attrs(dict(self.FULL))
        self.assertEqual(
            self.FULL, cleaned,
            "an attribute was dropped or truncated at intake — a truncated set "
            "is worse than a smaller deliberate one",
        )

    def test_the_fullest_set_is_inside_the_attribute_ceiling(self):
        self.assertLessEqual(len(self.FULL), traces.ATTR_MAX)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
