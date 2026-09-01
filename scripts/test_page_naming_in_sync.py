#!/usr/bin/env python3
"""The page-naming tables exist three times and cannot be shared. Pin them.

`spa/src/analytics/navigation.ts` owns the route table and the page-name rule
for every SPA transition. `spa/index.html`'s inline bootstrap owns the same two
things for the very FIRST beacon of every visit — it has to run before any
module evaluates, so it cannot import the module, and its copy is maintained by
hand. `spa/src/App.tsx` is the router that decides which paths actually exist.

That is the same duplication `test_telemetry_paths_complete.py` guards for
TELEMETRY_PATHS, and it has the same failure mode: a route is added to some
copies and not the others, and the symptom shows up in the vendor's UI (a page
named `*`, or an unnamed page-load beacon) rather than in a test. TELEMETRY_PATHS
was missed twice that way — `/eum`, then `/logs` — before it was pinned.

So: App.tsx is read as the AUTHORITY, not as a fourth hand-written list, and
both copies of ROUTES are pinned equal to it and to each other. The page-NAME
rule (operator decision 2026-09-01: name the concrete station, keep the route
pattern as meta) is pinned the same way, via the `STATION_ID` guard that decides
whether a param value is allowed into a page name at all.
"""

from __future__ import annotations

import pathlib
import re
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
NAV = REPO / "spa" / "src" / "analytics" / "navigation.ts"
HTML = REPO / "spa" / "index.html"
APP = REPO / "spa" / "src" / "App.tsx"

#: The router's catch-all. It is a real route, but it is not a page NAME the
#: bootstrap can match a path against — both copies encode it as the
#: `UNMATCHED_PATTERN` fallback instead, which is a different mechanism.
CATCH_ALL = "*"


def app_routes() -> list[str]:
    """Every path the router declares, from the router itself."""
    found = re.findall(r'path="([^"]+)"', APP.read_text())
    return [p for p in found if p != CATCH_ALL]


def nav_routes() -> list[str]:
    """navigation.ts's ROUTES — the canonical copy."""
    body = NAV.read_text().split("const ROUTES: readonly string[] = [", 1)[1].split("]", 1)[0]
    return re.findall(r"'([^']+)'", body)


def html_routes() -> list[str]:
    """The inline bootstrap's hand-duplicated copy."""
    body = HTML.read_text().split("var ROUTES = [", 1)[1].split("]", 1)[0]
    return re.findall(r"'([^']+)'", body)


def nav_station_id() -> str:
    """navigation.ts's syntactic bound on what may enter a page name."""
    return re.search(r"const STATION_ID = /(.+?)/;", NAV.read_text()).group(1)


def html_station_id() -> str:
    return re.search(r"var STATION_ID = /(.+?)/;", HTML.read_text()).group(1)


class TheThreeRouteTablesAgree(unittest.TestCase):
    def test_navigation_ts_matches_the_router(self):
        self.assertEqual(
            sorted(nav_routes()),
            sorted(app_routes()),
            "spa/src/analytics/navigation.ts's ROUTES disagrees with the routes "
            "spa/src/App.tsx actually declares. A path the table does not know "
            "is named '*' in both planes, so the page dimension silently loses "
            "it. Add it to ROUTES in navigation.ts AND in spa/index.html.",
        )

    def test_the_inline_bootstrap_copy_matches_the_module(self):
        self.assertEqual(
            sorted(html_routes()),
            sorted(nav_routes()),
            "spa/index.html's inline ROUTES copy has drifted from "
            "spa/src/analytics/navigation.ts. The bootstrap copy names the FIRST "
            "beacon of every visit, so a route missing here is a page-load beacon "
            "named '*' even though every subsequent transition is named correctly.",
        )


class TheStationIdGuardAgrees(unittest.TestCase):
    """The rule that decides page name vs. route pattern, in two languages.

    If the two guards disagree, the page-LOAD beacon and the page-TRANSITION
    beacon for the same station can carry different names — the aggregate would
    then be split across two rows for reasons no query can explain.
    """

    def test_the_two_copies_of_the_guard_are_identical(self):
        self.assertEqual(nav_station_id(), html_station_id())

    def test_the_guard_admits_every_registry_station_id(self):
        # The point of the whole change: a real station must reach the page
        # dimension by its own name. If a future id does not match, the page
        # silently degrades to the pattern and nobody notices.
        pattern = re.compile(nav_station_id())
        ids = sorted(p.stem for p in (REPO / "registry" / "stations").glob("*.json"))
        self.assertTrue(ids, "no registry stations found — the check would be vacuous")
        rejected = [i for i in ids if not pattern.fullmatch(i)]
        self.assertEqual(
            rejected,
            [],
            f"registry station id(s) {rejected} do not match STATION_ID, so they "
            f"would report as the route pattern instead of as themselves. Widen "
            f"the guard in BOTH navigation.ts and spa/index.html.",
        )

    def test_the_guard_still_rejects_what_it_exists_to_reject(self):
        pattern = re.compile(nav_station_id())
        for bad in ("", "../etc", "a" * 64, "Win95", "win 95", "win95?x=1", "1win"):
            with self.subTest(value=bad):
                self.assertIsNone(pattern.fullmatch(bad))


class NeitherCopyParsedVacuously(unittest.TestCase):
    """A guard on the guard, the same one test_telemetry_paths_complete.py keeps.

    Every assertion above compares two parsed lists. A restructure that defeats
    a regex would make both sides empty and every comparison trivially true, so
    the parsing itself is asserted against known content.
    """

    def test_each_route_table_actually_parsed(self):
        for name, got in (("app", app_routes()), ("nav", nav_routes()), ("html", html_routes())):
            with self.subTest(copy=name):
                self.assertIn("/os/:osId", got)
                self.assertIn("/walkin/play/:os", got)
                self.assertGreater(len(got), 5)

    def test_each_guard_actually_parsed(self):
        for name, got in (("nav", nav_station_id()), ("html", html_station_id())):
            with self.subTest(copy=name):
                self.assertTrue(got.startswith("^") and got.endswith("$"), got)
                self.assertIsNotNone(re.compile(got).fullmatch("win95"))

    def test_the_page_name_substitution_exists_in_both_copies(self):
        # The naming RULE itself, not just its guard: both copies must actually
        # substitute the param into the name and both must set the route
        # pattern as meta. Without this, a copy could keep a correct ROUTES
        # table and an identical regex while still emitting the old name.
        nav, html = NAV.read_text(), HTML.read_text()
        self.assertIn("STATION_ID.test(value) ? value : seg", nav)
        self.assertIn("ineum('page', pageName(event.pattern, event.params))", nav)
        self.assertIn("ineum('meta', 'kh.route.pattern', event.pattern)", nav)
        self.assertIn("if (v && STATION_ID.test(v)) parts[k] = v;", html)
        self.assertIn("ineum('page', name);", html)
        self.assertIn("ineum('meta', 'kh.route.pattern', pattern);", html)


if __name__ == "__main__":
    unittest.main()
