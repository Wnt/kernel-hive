"""Tests for WHAT AN EXPORTED TRACE CLAIMS ABOUT ITS PRODUCERS.

Separate from test_traces.py, which is about the store and the OTLP SPELLING.
Everything here is about identity and fidelity instead: which language a service
reports, which build produced a span, which of sixty-one daemons it was, and
whether the attributes a consumer renders actually survive our own intake to
reach the wire. Each test below corresponds to something that was measured wrong
against a live tenant on 2026-09-01, not to a hypothetical.
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "serve"))

import otlp_resource  # noqa: E402
import telemetry_paths  # noqa: E402
import traces  # noqa: E402
import traces_otlp  # noqa: E402

from test_traces import S1, S2, S3, T1, batch, span  # noqa: E402

SHA = "95ee4750adb39522410c1cb9d70f9fee99792f3e"
DAEMON_BUILD = "af4b82f36e84f1d0b4f56a97ed3229a369dbd92f"
SPAN_START = 1_700_000_000_000


def resources(doc):
    """{service.name: {resource attribute: value}} for one exported document."""
    out = {}
    for rs in doc["resourceSpans"]:
        keys = {a["key"]: next(iter(a["value"].values())) for a in rs["resource"]["attributes"]}
        out[keys["service.name"]] = keys
    return out


def span_attrs(doc, name):
    for rs in doc["resourceSpans"]:
        for s in rs["scopeSpans"][0]["spans"]:
            if s["name"] == name:
                return {a["key"]: next(iter(a["value"].values())) for a in s["attributes"]}
    raise AssertionError(f"no span named {name} in the export")


class FixtureBox:
    """A fake box tree: a `.deployed-rev` marker and a versioned station install.

    Real paths (`/data/vms/streamhost/.deployed-rev`, `/usr/local/lib/
    streamhost/stations`) are root-owned and only exist on labhost, so a test
    that read them would pass there and be vacuous everywhere else.
    """

    def __init__(self, tmp: Path, sha: str = SHA, artifact: str = f"streamhost-{DAEMON_BUILD}"):
        self.rev = tmp / "deployed-rev"
        self.rev.write_text(f"sha={sha}\nshort={sha[:8]}\nbranch=main\n")
        self.stations = tmp / "stations"
        target = tmp / artifact
        target.write_text("#!/bin/false\n")
        (self.stations / "solaris").mkdir(parents=True)
        self.link = self.stations / "solaris" / "current"
        self.link.symlink_to(target)
        # The daemon binary was installed BEFORE the spans under test, which is
        # the only case in which claiming it for them is true.
        installed = (SPAN_START - 60_000) / 1000.0
        os.utime(self.link, (installed, installed), follow_symlinks=False)

    def builds(self) -> otlp_resource.BuildIds:
        return otlp_resource.BuildIds(deployed_rev=self.rev, daemon_stations=self.stations)


class ExportCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store = traces.TraceStore(self.root / "traces.db")
        self.box = FixtureBox(self.root)

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def three_plane_trace(self, build="main@3e6c81c4"):
        """One trace with a span from each of the three producers, as a real
        `input.edge` journey has: the tab calls, the serving plane answers, the
        station's daemon does the work."""
        self.store.record(
            batch(
                [
                    span(S1, name="http.client.request", kind="client", start=SPAN_START),
                    span(
                        S2,
                        parent=S1,
                        name="serve.signal",
                        kind="server",
                        start=SPAN_START,
                        a={"kh.service": "kernel-hive-serve", "kh.station": "solaris"},
                    ),
                    span(
                        S3,
                        parent=S2,
                        name="input.dispatch",
                        kind="server",
                        start=SPAN_START,
                        a={"kh.service": "kernel-hive-daemon", "kh.station": "solaris"},
                    ),
                ],
                build=build,
            )
        )
        return traces_otlp.export(
            [self.store.trace(T1)],
            host_id="labhost",
            host_name="labhost",
            builds=self.box.builds(),
        )


class LanguageTest(ExportCase):
    """DEFECT 1. `telemetry.sdk.language` was computed as

        "python" if svc.endswith("-serve") else "webjs"

    so the Rust daemon — which does not end in `-serve` — left the box claiming
    to be browser JavaScript, on 275 spans in a six-hour sample. The comment
    directly above that line already spelled out why a wrong language is
    harmful; the code did not honour it."""

    def test_each_service_reports_the_language_it_is_actually_written_in(self):
        by_service = resources(self.three_plane_trace())
        self.assertEqual(by_service["kernel-hive-spa"]["telemetry.sdk.language"], "webjs")
        self.assertEqual(by_service["kernel-hive-serve"]["telemetry.sdk.language"], "python")
        self.assertEqual(by_service["kernel-hive-daemon"]["telemetry.sdk.language"], "rust")

    def test_the_daemon_is_not_labelled_a_browser(self):
        """The regression in one line, so a future refactor that reintroduces a
        name-suffix guess fails on the thing that was actually wrong."""
        by_service = resources(self.three_plane_trace())
        self.assertNotEqual(by_service["kernel-hive-daemon"]["telemetry.sdk.language"], "webjs")

    def test_an_undeclared_service_gets_no_language_rather_than_a_guess(self):
        """An absent attribute is a question a consumer can still ask. A guessed
        one is an answer it cannot doubt."""
        self.store.record(batch([span(S1, a={"kh.service": "kernel-hive-experiment"})]))
        doc = traces_otlp.export([self.store.trace(T1)], builds=self.box.builds())
        self.assertNotIn("telemetry.sdk.language", resources(doc)["kernel-hive-experiment"])

    def test_the_table_is_data_not_a_rule_about_names(self):
        self.assertEqual(otlp_resource.language_of("kernel-hive-daemon"), "rust")
        self.assertIsNone(otlp_resource.language_of("something-serve"))


class VersionTest(ExportCase):
    """DEFECT 2. `service.version` existed only for the browser, so "which build
    produced this span" was unanswerable for two thirds of the system."""

    def test_every_service_reports_a_version_from_its_own_source_of_truth(self):
        by_service = resources(self.three_plane_trace())
        self.assertEqual(by_service["kernel-hive-spa"]["service.version"], "main@3e6c81c4")
        self.assertEqual(by_service["kernel-hive-serve"]["service.version"], SHA)
        self.assertEqual(by_service["kernel-hive-daemon"]["service.version"], DAEMON_BUILD)

    def test_the_browsers_bundle_is_never_stamped_on_the_other_two(self):
        by_service = resources(self.three_plane_trace())
        self.assertNotEqual(by_service["kernel-hive-serve"]["service.version"], "main@3e6c81c4")
        self.assertNotEqual(by_service["kernel-hive-daemon"]["service.version"], "main@3e6c81c4")

    def test_an_unreadable_source_omits_the_version_rather_than_inventing_one(self):
        """Off the box — CT950, CI, a laptop — neither path exists. The
        attribute must then be absent, never "unknown": a consumer grouping by
        version cannot tell a placeholder from a release name."""
        missing = otlp_resource.BuildIds(deployed_rev=self.root / "nope", daemon_stations=self.root / "nowhere")
        self.store.record(batch([span(S1, name="serve.signal", kind="server", a={"kh.service": "kernel-hive-serve"})]))
        doc = traces_otlp.export([self.store.trace(T1)], builds=missing)
        self.assertNotIn("service.version", resources(doc)["kernel-hive-serve"])

    def test_a_half_written_marker_is_refused(self):
        bad = self.root / "half"
        bad.write_text("sha=95ee47\nbranch=main\n")
        self.assertIsNone(otlp_resource.BuildIds(deployed_rev=bad).serve())

    def test_a_binary_installed_after_the_span_is_not_claimed_for_it(self):
        """A canary swap between the span and the forward would otherwise
        attribute a span to a build that did not exist when it was produced —
        the exact fabricated fact `service.version` is supposed to prevent."""
        later = (SPAN_START + 3_600_000) / 1000.0
        os.utime(self.box.link, (later, later), follow_symlinks=False)
        by_service = resources(self.three_plane_trace())
        self.assertNotIn("service.version", by_service["kernel-hive-daemon"])
        # …and the two planes that CAN answer are unaffected by the gap.
        self.assertEqual(by_service["kernel-hive-serve"]["service.version"], SHA)

    def test_a_hand_built_artifact_is_a_real_build_id_too(self):
        tmp = Path(tempfile.mkdtemp(dir=self.root))
        box = FixtureBox(tmp, artifact="streamhost-nt351-326d8bfa4243573f")
        self.assertEqual(box.builds().daemon("solaris", SPAN_START), "nt351-326d8bfa4243573f")


class InstanceTest(ExportCase):
    """`service.instance.id` is on Instana's consumed list and was absent. Sixty
    one daemons merged into one node is a service map that cannot say which
    machine was asleep."""

    def test_each_service_names_the_instance_that_produced_the_span(self):
        by_service = resources(self.three_plane_trace())
        self.assertEqual(by_service["kernel-hive-spa"]["service.instance.id"], "sess-abc")
        self.assertEqual(by_service["kernel-hive-serve"]["service.instance.id"], "labhost")
        self.assertEqual(by_service["kernel-hive-daemon"]["service.instance.id"], "solaris")

    def test_two_stations_are_two_resources_not_one(self):
        self.store.record(
            batch(
                [
                    span(S1, name="input.dispatch", a={"kh.service": "kernel-hive-daemon", "kh.station": "irix"}),
                    span(S2, name="guest.frame.next", a={"kh.service": "kernel-hive-daemon", "kh.station": "beos"}),
                ]
            )
        )
        doc = traces_otlp.export([self.store.trace(T1)], builds=self.box.builds())
        stations = {
            keys["service.instance.id"]
            for keys in (
                {a["key"]: next(iter(a["value"].values())) for a in rs["resource"]["attributes"]}
                for rs in doc["resourceSpans"]
            )
            if keys["service.name"] == "kernel-hive-daemon"
        }
        self.assertEqual(stations, {"irix", "beos"})

    def test_the_host_is_named_for_instana_to_correlate(self):
        by_service = resources(self.three_plane_trace())
        self.assertEqual(by_service["kernel-hive-serve"]["host.name"], "labhost")
        self.assertEqual(by_service["kernel-hive-serve"]["host.id"], "labhost")


class InstanaAttributeTest(ExportCase):
    """THE BROADER ASK. Instana's documented consumed set is the PREVIOUS
    generation of the HTTP conventions; this plane emits the current ones. The
    bridge is additive and lives at the export boundary — and it is only worth
    anything if the attributes it derives from survived our own intake."""

    def entry_span(self, **attrs):
        base = {
            "kh.service": "kernel-hive-serve",
            "http.request.method": "GET",
            "http.route": "/station/{id}/signal",
            "server.address": "gallery.example.com",
            "http.response.status_code": 200,
        }
        base.update(attrs)
        self.store.record(batch([span(S1, name="serve.signal", kind="server", a=base)]))
        doc = traces_otlp.export([self.store.trace(T1)], builds=self.box.builds())
        return span_attrs(doc, "serve.signal")

    def test_the_entry_spans_attributes_reach_the_wire_in_both_spellings(self):
        a = self.entry_span()
        self.assertEqual(a["http.request.method"], "GET")  # ours, untouched
        self.assertEqual(a["http.method"], "GET")  # Instana's
        self.assertEqual(a["http.status_code"], "200")
        self.assertEqual(a["http.host"], "gallery.example.com")
        self.assertEqual(a["http.route"], "/station/{id}/signal")

    def test_a_server_spans_own_address_is_not_reported_as_the_peer(self):
        """On an entry span `server.address` is OUR authority. Calling it
        `net.peer.name` would name the wrong machine on every service map."""
        self.assertNotIn("net.peer.name", self.entry_span())

    def exit_span(self):
        self.store.record(
            batch(
                [
                    span(
                        S1,
                        name="http.client.request",
                        kind="client",
                        a={
                            "http.request.method": "POST",
                            "url.path": "/walkin/claim",
                            "url.scheme": "https",
                            "server.address": "gallery.example.com",
                            "server.port": 443,
                            "http.response.status_code": 200,
                        },
                    )
                ]
            )
        )
        doc = traces_otlp.export([self.store.trace(T1)], builds=self.box.builds())
        return span_attrs(doc, "http.client.request")

    def test_an_exit_span_carries_the_peer_attributes_a_service_map_needs(self):
        a = self.exit_span()
        self.assertEqual(a["net.peer.name"], "gallery.example.com")
        self.assertEqual(a["net.peer.port"], "443")
        self.assertEqual(a["http.host"], "gallery.example.com")
        self.assertEqual(a["peer.service"], "kernel-hive-serve")
        self.assertEqual(a["http.target"], "/walkin/claim")
        self.assertEqual(a["http.scheme"], "https")

    def test_http_url_is_populated_and_carries_no_query_string(self):
        """`traces.py` BANNED_ATTRS refuses `url.full` and `url.query` outright,
        so Instana's `http.url` pane can only be filled from parts. What it
        costs is exactly the query string, and that is the intended trade."""
        url = self.exit_span()["http.url"]
        self.assertEqual(url, "https://gallery.example.com/walkin/claim")
        self.assertNotIn("?", url)

    def test_the_banned_attributes_still_cannot_reach_the_wire(self):
        self.store.record(
            batch(
                [
                    span(
                        S1,
                        name="http.client.request",
                        kind="client",
                        a={"url.full": "https://x/y?ticket=secret", "url.query": "ticket=secret", "url.path": "/y"},
                    )
                ]
            )
        )
        doc = traces_otlp.export([self.store.trace(T1)], builds=self.box.builds())
        a = span_attrs(doc, "http.client.request")
        self.assertNotIn("url.full", a)
        self.assertNotIn("url.query", a)
        self.assertNotIn("http.url", a)  # no scheme/host survived, so none is invented
        self.assertEqual(a["http.target"], "/y")

    def test_a_producers_own_value_is_never_overwritten_by_the_bridge(self):
        self.assertEqual(self.entry_span(**{"http.method": "PATCH"})["http.method"], "PATCH")

    def test_the_browser_client_span_emits_the_parts_the_bridge_needs(self):
        """The bridge can only derive from what `spa/src/analytics/khFetch.ts`
        actually sets. Pinned here in Python because the cost of the TypeScript
        quietly dropping one of these is an empty pane nobody notices."""
        src = (Path(__file__).resolve().parents[1] / "spa" / "src" / "analytics" / "khFetch.ts").read_text()
        for attr in ("http.request.method", "url.path", "url.scheme", "server.address", "server.port"):
            self.assertIn(f"'{attr}'", src, f"khFetch.ts no longer sets {attr}")


class SyntheticTest(ExportCase):
    """Analytics -> Calls was 896 calls in an hour and almost all of them ours:
    `serve.clientcmd`, `serve.clientlog`, `serve.analytics`. Instana's own
    Synthetic mechanism hides those by default and keeps them one switch away;
    the mark belongs on the WIRE and never in the store."""

    def exported(self, route, name, kind="server"):
        self.store.record(
            batch([span(S1, name=name, kind=kind, a={"kh.service": "kernel-hive-serve", "http.route": route})])
        )
        doc = traces_otlp.export([self.store.trace(T1)], builds=self.box.builds())
        return span_attrs(doc, name)

    def test_the_polling_plane_is_marked_synthetic(self):
        for route, name in (
            ("/clientcmd", "serve.clientcmd"),
            ("/clientlog", "serve.clientlog"),
            ("/analytics", "serve.analytics"),
            ("/usage", "serve.usage"),
        ):
            with self.subTest(route=route):
                self.tearDown()
                self.setUp()
                self.assertTrue(self.exported(route, name)["synthetic"])

    def test_serve_signal_is_never_marked_it_is_a_visitor_opening_a_station(self):
        """The boundary that matters most. `/signal/{station}.json` is the first
        thing that happens when somebody opens a machine; hiding it would hide
        the gallery's own front door."""
        self.assertNotIn("synthetic", self.exported("/signal/{station}.json", "serve.signal"))

    def test_the_read_side_of_a_telemetry_subtree_stays_visible(self):
        """Somebody has /admin open and is waiting. Exact matching, not a prefix
        test, is what keeps these out of the hidden set."""
        for route, name in (
            ("/analytics/report.json", "serve.analytics.report.json"),
            ("/coverage/report.json", "serve.coverage.report.json"),
            ("/usage/stations.json", "serve.usage.stations.json"),
        ):
            with self.subTest(route=route):
                self.tearDown()
                self.setUp()
                self.assertNotIn("synthetic", self.exported(route, name))

    def test_only_entry_spans_are_marked(self):
        self.assertNotIn("synthetic", self.exported("/clientcmd", "serve.clientcmd", kind="internal"))

    def test_the_mark_is_on_the_wire_and_not_in_the_store(self):
        """Rule four of the brief, as an assertion: our own plane keeps these
        spans first-class. A `synthetic` attribute in traces.db would leak a
        vendor's presentation vocabulary into /admin/observability."""
        self.store.record(
            batch(
                [
                    span(
                        S1,
                        name="serve.clientcmd",
                        kind="server",
                        a={"kh.service": "kernel-hive-serve", "http.route": "/clientcmd"},
                    )
                ]
            )
        )
        stored = self.store.trace(T1)["spans"][0]["attributes"]
        self.assertNotIn("synthetic", stored)
        doc = traces_otlp.export([self.store.trace(T1)], builds=self.box.builds())
        self.assertTrue(span_attrs(doc, "serve.clientcmd")["synthetic"])

    def test_the_mark_is_a_boolean_not_the_string_true(self):
        """OTLP AnyValue types are load-bearing: `"true"` is a string and would
        not satisfy "annotated with synthetic with the value true"."""
        self.store.record(
            batch(
                [
                    span(
                        S1,
                        name="serve.clientcmd",
                        kind="server",
                        a={"kh.service": "kernel-hive-serve", "http.route": "/clientcmd"},
                    )
                ]
            )
        )
        doc = traces_otlp.export([self.store.trace(T1)], builds=self.box.builds())
        for rs in doc["resourceSpans"]:
            for sp in rs["scopeSpans"][0]["spans"]:
                for a in sp["attributes"]:
                    if a["key"] == "synthetic":
                        self.assertEqual(a["value"], {"boolValue": True})
                        return
        raise AssertionError("no synthetic attribute was exported")

    def test_the_python_list_mirrors_the_typescript_one(self):
        """One source of truth, two languages. A path added to the SPA's
        `KH_TELEMETRY_PATHS` and forgotten here would keep polling the tenant's
        call list forever, which is the drift this test exists to prevent."""
        src = (Path(__file__).resolve().parents[1] / "spa" / "src" / "analytics" / "instana.ts").read_text()
        body = src.split("export const KH_TELEMETRY_PATHS = [", 1)[1].split("]", 1)[0]
        typescript = set(re.findall(r"'([^']+)'", body))
        self.assertEqual(typescript, set(telemetry_paths.TELEMETRY_PATHS))


if __name__ == "__main__":
    unittest.main()
