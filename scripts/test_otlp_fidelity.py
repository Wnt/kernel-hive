"""Tests for WHAT AN EXPORTED TRACE CLAIMS ABOUT ITS PRODUCERS.

Separate from test_traces.py, which is about the store and the OTLP SPELLING.
Everything here is about identity and fidelity instead: which language a service
reports, which build produced a span, which of sixty-one daemons it was, and
whether the attributes a consumer renders actually survive our own intake to
reach the wire. Each test below corresponds to something that was measured wrong
in a live export on 2026-09-01, not to a hypothetical.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "serve"))

import otlp_resource  # noqa: E402
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
    """`service.instance.id` was absent. Sixty one daemons merged into one node
    is a service map that cannot say which machine was asleep."""

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

    def test_the_serving_plane_names_its_host(self):
        by_service = resources(self.three_plane_trace())
        self.assertEqual(by_service["kernel-hive-serve"]["host.name"], "labhost")


class AttributeFidelityTest(ExportCase):
    """An export is a faithful rendering of the store: the attributes a
    producer set reach the wire under exactly the names it used, nothing is
    renamed and nothing is invented — and that is only worth anything if they
    survived our own intake first."""

    ENTRY = {
        "kh.service": "kernel-hive-serve",
        "http.request.method": "GET",
        "http.route": "/station/{id}/signal",
        "server.address": "gallery.example.com",
        "http.response.status_code": 200,
    }

    def entry_span(self):
        self.store.record(batch([span(S1, name="serve.signal", kind="server", a=dict(self.ENTRY))]))
        doc = traces_otlp.export([self.store.trace(T1)], builds=self.box.builds())
        return span_attrs(doc, "serve.signal")

    def test_the_entry_spans_attributes_reach_the_wire_unchanged(self):
        a = self.entry_span()
        self.assertEqual(a["http.request.method"], "GET")
        self.assertEqual(a["http.response.status_code"], "200")
        self.assertEqual(a["server.address"], "gallery.example.com")
        self.assertEqual(a["http.route"], "/station/{id}/signal")

    def test_the_export_adds_no_attribute_the_producer_did_not_set(self):
        self.assertEqual(set(self.entry_span()), set(self.ENTRY))

    def test_a_credential_in_a_url_still_cannot_reach_the_wire(self):
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
        # URLs travel now (docs/ANALYTICS.md §0) — but a credential inside one
        # does not. `signal_route.py` mints the stream ticket INTO a query
        # string because the raw WebTransport plane has no headers, so an
        # unredacted url.full for a stream connect would be a stored credential.
        self.assertIn("url.full", a)
        self.assertEqual(a["url.full"], "https://x/y?ticket=REDACTED")
        self.assertEqual(a["url.query"], "ticket=REDACTED")
        self.assertNotIn("secret", a["url.full"])
        self.assertEqual(a["url.path"], "/y")


if __name__ == "__main__":
    unittest.main()
