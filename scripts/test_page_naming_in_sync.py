#!/usr/bin/env python3
"""The page-naming route table is a copy of the router's. Pin it.

`spa/src/analytics/navigation.ts` owns the route table and the page-name rule
for every SPA transition (the `app.page` span's `kh.page.name` and
`kh.route.pattern`). `spa/src/App.tsx` is the router that decides which paths
actually exist. A route added to the router and not to the table is named `*`,
so the page dimension silently loses it.

So: App.tsx is read as the AUTHORITY, not as a second hand-written list, and
navigation.ts's ROUTES is pinned equal to it. The page-NAME rule (operator
decision 2026-09-01: name the concrete station, keep the route pattern beside
it) is pinned too, via the `STATION_ID` guard that decides whether a param value
is allowed into a page name at all.
"""

from __future__ import annotations

import pathlib
import re
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
NAV = REPO / "spa" / "src" / "analytics" / "navigation.ts"
APP = REPO / "spa" / "src" / "App.tsx"

#: The router's catch-all. It is a real route, but it is not a page NAME the
#: table can match a path against — navigation.ts encodes it as the
#: `UNMATCHED_PATTERN` fallback instead, which is a different mechanism.
CATCH_ALL = "*"


def app_routes() -> list[str]:
    """Every path the router declares, from the router itself."""
    found = re.findall(r'path="([^"]+)"', APP.read_text())
    return [p for p in found if p != CATCH_ALL]


def nav_routes() -> list[str]:
    """navigation.ts's ROUTES."""
    body = NAV.read_text().split("const ROUTES: readonly string[] = [", 1)[1].split("]", 1)[0]
    return re.findall(r"'([^']+)'", body)


def nav_station_id() -> str:
    """navigation.ts's syntactic bound on what may enter a page name."""
    return re.search(r"const STATION_ID = /(.+?)/;", NAV.read_text()).group(1)


class TheRouteTableMatchesTheRouter(unittest.TestCase):
    def test_navigation_ts_matches_the_router(self):
        self.assertEqual(
            sorted(nav_routes()),
            sorted(app_routes()),
            "spa/src/analytics/navigation.ts's ROUTES disagrees with the routes "
            "spa/src/App.tsx actually declares. A path the table does not know "
            "is named '*', so the page dimension silently loses it. Add it to "
            "ROUTES in navigation.ts.",
        )


class TheStationIdGuard(unittest.TestCase):
    """The rule that decides page name vs. route pattern."""

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
            f"the guard in navigation.ts.",
        )

    def test_the_guard_still_rejects_what_it_exists_to_reject(self):
        pattern = re.compile(nav_station_id())
        for bad in ("", "../etc", "a" * 64, "Win95", "win 95", "win95?x=1", "1win"):
            with self.subTest(value=bad):
                self.assertIsNone(pattern.fullmatch(bad))


class NothingParsedVacuously(unittest.TestCase):
    """A guard on the guard, the same one test_telemetry_paths_complete.py keeps.

    Every assertion above compares parsed content. A restructure that defeats a
    regex would make both sides empty and every comparison trivially true, so
    the parsing itself is asserted against known content.
    """

    def test_each_route_table_actually_parsed(self):
        for name, got in (("app", app_routes()), ("nav", nav_routes())):
            with self.subTest(copy=name):
                self.assertIn("/os/:osId", got)
                self.assertIn("/walkin/play/:os", got)
                self.assertGreater(len(got), 5)

    def test_the_guard_actually_parsed(self):
        got = nav_station_id()
        self.assertTrue(got.startswith("^") and got.endswith("$"), got)
        self.assertIsNotNone(re.compile(got).fullmatch("win95"))

    def test_the_page_name_substitution_exists(self):
        # The naming RULE itself, not just its guard: navigation.ts must
        # actually substitute the param into the name.
        self.assertIn("STATION_ID.test(value) ? value : seg", NAV.read_text())


if __name__ == "__main__":
    unittest.main()
