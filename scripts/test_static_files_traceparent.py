"""Tests for the `<meta name="traceparent">` injection into index.html.

docs/lab/TRACE-CONTEXT.md §8: a page load joins a backend trace only because
the SERVER embeds a real, recorded span's id in the HTML it serves — Instana's
own (undocumented) website-monitoring agent reads exactly
`document.querySelector('meta[name="traceparent"]')`. The rules that matter:

  * the tag's `content` is well-formed `00-<32hex>-<16hex>-<2hex>` and names a
    span this process actually recorded, not an id invented only for the tag;
  * `spa/index.html` on disk is never touched — only the served BYTES;
  * a telemetry problem (tracing unbound, anything raising) must serve the
    ORIGINAL bytes, byte-for-byte, never break the page;
  * no file other than index.html is ever modified.
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "serve"))

_WEBROOT_TMP = tempfile.TemporaryDirectory()
WEBROOT = Path(_WEBROOT_TMP.name)

INDEX_HTML = (
    b'<!doctype html>\n<html lang="en">\n  <head>\n    <meta charset="UTF-8" />\n'
    b'    <title>Kernel Hive</title>\n  </head>\n  <body><div id="root"></div></body>\n</html>\n'
)
(WEBROOT / "index.html").write_bytes(INDEX_HTML)
(WEBROOT / "assets").mkdir()
APP_JS = b"console.log('app');\n"
(WEBROOT / "assets" / "app-abcdef01.js").write_bytes(APP_JS)
(WEBROOT / "staging").mkdir()
(WEBROOT / "staging" / "sess1").mkdir()
STAGED_INDEX_HTML = INDEX_HTML.replace(b"Kernel Hive", b"Kernel Hive (staging)")
(WEBROOT / "staging" / "sess1" / "index.html").write_bytes(STAGED_INDEX_HTML)

os.environ.setdefault("WEBROOT", str(WEBROOT))
os.environ.setdefault("SIGNAL_CONFIG", str(WEBROOT / "signal.json"))
(WEBROOT / "signal.json").write_text("{}")
os.environ.setdefault("CERT", "unused-in-tests")
os.environ.setdefault("KEY", "unused-in-tests")

import static_files  # noqa: E402
import traces  # noqa: E402
import tracing  # noqa: E402

TAG_RE = re.compile(rb'<meta name="traceparent" content="([0-9a-f-]+)">')


class FakeHandler:
    """The narrowest thing `serve_static` needs off a request handler."""

    public = False

    def __init__(self, headers=None):
        self.headers = headers or {}
        self.command = "GET"
        self.replied = None

    def _send(self, code, body, ctype, cache=True, extra=None):
        self.replied = (code, body, ctype, cache, extra)

    def _cors(self):
        pass


class Base(unittest.TestCase):
    def setUp(self):
        tracing.reset_for_tests()
        self.tmp = tempfile.TemporaryDirectory()
        self.store = traces.TraceStore(Path(self.tmp.name) / "traces.db")

    def tearDown(self):
        tracing.reset_for_tests()
        self.store.close()
        self.tmp.cleanup()


class TracingOnTest(Base):
    def setUp(self):
        super().setUp()
        tracing.bind(self.store)

    def _get(self, path="/"):
        h = FakeHandler()
        static_files.serve_static(h, path)
        return h

    def test_the_tag_is_present_and_well_formed(self):
        h = self._get("/")
        code, body, ctype, cache, extra = h.replied
        self.assertEqual(code, 200)
        m = TAG_RE.search(body)
        self.assertIsNotNone(m, body)
        parts = m.group(1).decode("ascii").split("-")
        self.assertEqual(len(parts), 4)
        version, trace_id, span_id, flags = parts
        self.assertEqual(version, "00")
        self.assertRegex(trace_id, r"^[0-9a-f]{32}$")
        self.assertRegex(span_id, r"^[0-9a-f]{16}$")
        self.assertRegex(flags, r"^[0-9a-f]{2}$")

    def test_the_tag_names_a_span_this_process_actually_recorded(self):
        h = self._get("/")
        trace_id = TAG_RE.search(h.replied[1]).group(1).decode("ascii").split("-")[1]
        tracing.flush()
        doc = self.store.trace(trace_id)
        self.assertIsNotNone(doc)
        self.assertEqual(doc["spans"][0]["name"], "serve.page")

    def test_the_tag_lands_inside_head_before_the_title(self):
        h = self._get("/")
        body = h.replied[1]
        head_idx = body.index(b"<head>")
        title_idx = body.index(b"<title>")
        tag_idx = TAG_RE.search(body).start()
        self.assertTrue(head_idx < tag_idx < title_idx)

    def test_a_non_index_asset_is_never_modified(self):
        h = self._get("/assets/app-abcdef01.js")
        code, body, ctype, cache, extra = h.replied
        self.assertEqual(code, 200)
        self.assertEqual(body, APP_JS)

    def test_the_spa_client_route_fallback_also_gets_the_tag(self):
        # "/os/win95" has no dot, no file on disk -> falls back to index.html,
        # the same bytes a direct navigation to it would serve.
        h = self._get("/os/win95")
        self.assertIsNotNone(TAG_RE.search(h.replied[1]))

    def test_staging_index_html_gets_its_own_tag_and_is_not_the_live_one(self):
        h = self._get("/staging/sess1/")
        body = h.replied[1]
        self.assertIn(b"Kernel Hive (staging)", body)
        self.assertIsNotNone(TAG_RE.search(body))

    def test_repeated_requests_mint_distinct_spans(self):
        first = TAG_RE.search(self._get("/").replied[1]).group(1)
        second = TAG_RE.search(self._get("/").replied[1]).group(1)
        self.assertNotEqual(first, second)


class TracingOffTest(Base):
    """No `tracing.bind()` in setUp: tracing is unavailable, the way a dev
    server with no store attached would leave it."""

    def test_index_html_is_byte_identical_to_the_original(self):
        h = FakeHandler()
        static_files.serve_static(h, "/")
        code, body, ctype, cache, extra = h.replied
        self.assertEqual(code, 200)
        self.assertEqual(body, INDEX_HTML)

    def test_a_non_index_asset_is_never_modified(self):
        h = FakeHandler()
        static_files.serve_static(h, "/assets/app-abcdef01.js")
        self.assertEqual(h.replied[1], APP_JS)


class FailSafeTest(Base):
    """Tracing IS bound, but the injection path itself is broken — the tag
    generator must still never take the page down with it."""

    def setUp(self):
        super().setUp()
        tracing.bind(self.store)

    def test_a_traceparent_meta_that_raises_serves_the_original_bytes(self):
        original = static_files._traceparent_meta
        static_files._traceparent_meta = lambda handler: (_ for _ in ()).throw(RuntimeError("boom"))
        try:
            h = FakeHandler()
            static_files.serve_static(h, "/")
            self.assertEqual(h.replied[1], INDEX_HTML)
        finally:
            static_files._traceparent_meta = original

    def test_html_with_no_head_tag_is_served_unchanged(self):
        weird = WEBROOT / "staging" / "noheadtest"
        weird.mkdir()
        no_head = b"<!doctype html>\n<html><body>no head here</body></html>\n"
        (weird / "index.html").write_bytes(no_head)
        h = FakeHandler()
        static_files.serve_static(h, "/staging/noheadtest/")
        self.assertEqual(h.replied[1], no_head)


if __name__ == "__main__":
    unittest.main()
