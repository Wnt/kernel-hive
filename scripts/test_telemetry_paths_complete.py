#!/usr/bin/env python3
"""Every route that INGESTS our own telemetry must be a known telemetry path.

This has now been missed twice. `/eum` was added when the beacon proxy landed
and had to be chased down; `/logs` was added with the log plane and was not,
so Instana's wrapped fetch beaconed every log upload into the Page load
Activity view — a telemetry endpoint generating telemetry about itself.

The list is the single source (`telemetry_paths.TELEMETRY_PATHS`, mirrored
from the SPA's `KH_TELEMETRY_PATHS`), so the failure mode is always the same:
someone adds an ingest route and does not add it to the list. This test reads
the DISPATCHER rather than a second hand-written list, so a new route fails
here on the commit that introduces it.
"""

from __future__ import annotations

import pathlib
import re
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "serve"))

import telemetry_paths  # noqa: E402

ROUTES = pathlib.Path(__file__).resolve().parent / "serve" / "telemetry_routes.py"
REPO = pathlib.Path(__file__).resolve().parents[1]
TS_SOURCE = REPO / "spa" / "src" / "analytics" / "instana.ts"
HTML_SOURCE = REPO / "spa" / "index.html"

#: Routes the dispatcher serves that are READS, not ingest. A report a human
#: opens is ordinary traffic and should stay visible in both planes.
READ_ROUTES = {"/analytics/report.json", "/coverage/report.json", "/usage/stations.json"}


def ingest_routes() -> set[str]:
    """Literal paths the telemetry dispatcher answers, minus the read side."""
    src = ROUTES.read_text()
    found = set(re.findall(r'path == "(/[a-z0-9./_-]+)"', src))
    return {p for p in found if p not in READ_ROUTES}


class TelemetryPathsAreComplete(unittest.TestCase):
    def test_every_ingest_route_is_a_known_telemetry_path(self):
        missing = sorted(ingest_routes() - set(telemetry_paths.TELEMETRY_PATHS))
        self.assertEqual(
            missing,
            [],
            f"ingest route(s) {missing} are not in TELEMETRY_PATHS — the browser will "
            f"trace them and Instana will beacon them, so telemetry measures itself. "
            f"Add them to spa/src/analytics/instana.ts's KH_TELEMETRY_PATHS and to "
            f"scripts/serve/telemetry_paths.py.",
        )

    def test_the_dispatcher_actually_parsed(self):
        # A guard on the guard: if the dispatcher is restructured so the regex
        # finds nothing, this test would pass vacuously forever.
        self.assertIn("/traces", ingest_routes())
        self.assertIn("/logs", ingest_routes())


if __name__ == "__main__":
    unittest.main()


def ts_paths() -> list[str]:
    """The SPA module's list — the one khFetch derives its ignore test from."""
    src = TS_SOURCE.read_text()
    body = src.split("export const KH_TELEMETRY_PATHS = [", 1)[1].split("]", 1)[0]
    return re.findall(r"'(/[^']+)'", body)


def html_paths() -> list[str]:
    """The inline bootstrap's copy — it runs before any module evaluates, so it
    cannot import the constant and is duplicated by hand."""
    src = HTML_SOURCE.read_text()
    body = src.split("var TELEMETRY_PATHS = [", 1)[1].split("]", 1)[0]
    return re.findall(r"'(/[^']+)'", body)


class TheThreeCopiesAgree(unittest.TestCase):
    """The list exists three times, in three languages, and cannot be shared.

    `index.html`'s copy runs before any module evaluates; the Python copy is in
    another process entirely. Sharing them would need a build step none of the
    three currently has, so instead they are pinned equal here. Both /eum and
    /logs were added to SOME of them and not the others, and each time the
    symptom appeared in the vendor's UI rather than in a test.
    """

    def test_the_typescript_and_python_lists_are_identical(self):
        self.assertEqual(sorted(ts_paths()), sorted(telemetry_paths.TELEMETRY_PATHS))

    def test_the_inline_bootstrap_copy_matches_the_module(self):
        self.assertEqual(sorted(html_paths()), sorted(ts_paths()))

    def test_each_copy_actually_parsed(self):
        # Vacuous-pass guard: a restructure that defeats the parsing must fail
        # here rather than quietly asserting nothing.
        for name, got in (("ts", ts_paths()), ("html", html_paths())):
            with self.subTest(copy=name):
                self.assertIn("/traces", got)
                self.assertGreater(len(got), 3)
