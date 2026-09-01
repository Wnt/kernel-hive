"""Does the stream-event vocabulary survive our OWN intake?

A whole span family was once silently dropped because its name contained a
space (see the comment at spa/src/analytics/khFetch.ts:184-196): the browser
sent it, `/traces` refused it, and nothing anywhere said so. An event
vocabulary that cannot be stored is worse than no vocabulary, because the
report reads zero and a zero looks like a finding.

So this test reads the REAL declarations out of the SPA source and runs them
through the REAL server-side validators — `scripts/serve/traces.py` for span
names and attributes, `scripts/serve/analytics.py` for probe and metric ids —
rather than against a copy of the rules that could drift from either side.

Parsing TypeScript with a regex is a deliberate, narrow choice: the alternative
is a Node build step inside a Python unittest, and the thing being extracted is
a list of quoted string literals in one object literal. If the extraction ever
finds nothing, that is a FAILURE here, not a silent pass — which is the one
failure mode a lazy regex-based test usually has.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "serve"))

import traces  # noqa: E402

import analytics  # noqa: E402

SPA = ROOT / "spa" / "src"
TAXONOMY = SPA / "analytics" / "streamEvents.ts"
CATALOGUE = SPA / "analytics" / "catalogue" / "stream.ts"
#: Every module that builds attributes for a stream event. A `kh.` key
#: appearing in any of them ends up on a span, so all of them are in scope.
EMITTERS = (
    TAXONOMY,
    SPA / "analytics" / "pageBinding.ts",
    SPA / "three" / "streamClient" / "analyticsEvents.ts",
    SPA / "three" / "sessionTelemetry.ts",
    SPA / "three" / "streamClient" / "resumePolicy.ts",
    SPA / "three" / "streamClient" / "softwareDecodeLatch.ts",
)

#: A top-level key of the STREAM_EVENTS literal: `'stream.x.y': {`.
EVENT_KEY_RE = re.compile(r"^  '(stream\.[A-Za-z0-9.]+)': \{$", re.MULTILINE)
#: Any attribute key this plane writes. Both namespaces travel on a span.
ATTR_RE = re.compile(r"'((?:kh|error)\.[A-Za-z0-9._]+)'")
#: A declared probe or metric id in the catalogue file.
CATALOGUE_ID_RE = re.compile(r"^  '(stream\.[A-Za-z0-9.]+)': \{$", re.MULTILINE)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class ExtractionTest(unittest.TestCase):
    """The regexes above must actually find something, or every test below is
    a vacuous pass over an empty list."""

    def test_finds_the_event_names(self):
        self.assertGreaterEqual(len(EVENT_KEY_RE.findall(read(TAXONOMY))), 10)

    def test_finds_the_attribute_keys(self):
        found = set()
        for path in EMITTERS:
            found |= set(ATTR_RE.findall(read(path)))
        self.assertGreaterEqual(len(found), 20)

    def test_finds_the_catalogue_ids(self):
        self.assertGreaterEqual(len(CATALOGUE_ID_RE.findall(read(CATALOGUE))), 15)


class SpanIntakeTest(unittest.TestCase):
    """`scripts/serve/traces.py` is the authority. These are its rules."""

    def setUp(self):
        self.events = EVENT_KEY_RE.findall(read(TAXONOMY))
        self.attrs = sorted({a for p in EMITTERS for a in ATTR_RE.findall(read(p))})

    def test_every_event_name_is_a_storable_span_name(self):
        for name in self.events:
            with self.subTest(name=name):
                self.assertRegex(name, traces.NAME_RE)
                # The specific trap, stated: no spaces. A name with one is
                # accepted by the browser, refused here, and reported nowhere.
                self.assertNotIn(" ", name)

    def test_no_attribute_is_banned_outright(self):
        for attr in self.attrs:
            with self.subTest(attr=attr):
                self.assertNotIn(attr, traces.BANNED_ATTRS)

    def test_every_attribute_key_survives_cleaning(self):
        # `_clean_attrs` drops a key longer than 64 characters silently.
        cleaned = traces._clean_attrs({a: "v" for a in self.attrs[: traces.ATTR_MAX]})
        self.assertEqual(sorted(cleaned), sorted(self.attrs[: traces.ATTR_MAX]))
        for attr in self.attrs:
            with self.subTest(attr=attr):
                self.assertLessEqual(len(attr), 64)

    def test_no_single_event_can_exceed_the_attribute_cap(self):
        """An event whose OWN attributes plus the page binding plus the station
        dimensions exceed ATTR_MAX would have evidence silently truncated."""
        source = read(TAXONOMY)
        # Per-event `attrs: [...]` blocks, in declaration order.
        blocks = re.findall(r"attrs: \[(.*?)\],", source, re.DOTALL)
        self.assertEqual(len(blocks), len(self.events))
        # 3 page-binding keys + kh.sample.n + kh.metric.* + 4 station dimensions.
        overhead = 9
        for name, block in zip(self.events, blocks):
            with self.subTest(name=name):
                count = len(re.findall(r"'[^']+'", block))
                self.assertLessEqual(count + overhead, traces.ATTR_MAX)


class CatalogueIdTest(unittest.TestCase):
    """Probe and metric rows land in the same table the client's do, and
    `scripts/serve/analytics.py` refuses an id its grammar does not accept —
    which would make the probe read zero forever."""

    def test_every_declared_id_is_a_storable_probe_id(self):
        for ident in CATALOGUE_ID_RE.findall(read(CATALOGUE)):
            with self.subTest(ident=ident):
                self.assertRegex(ident, analytics.ID_RE)


if __name__ == "__main__":
    unittest.main()
