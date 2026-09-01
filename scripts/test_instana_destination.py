#!/usr/bin/env python3
"""Tests for instana_destination.py — which of the two Instana doors
instana-forward.py talks to, and the narrow loopback-http exception.

No network, no trace store, no real Instana tenant: `choose_destination`
takes an injectable `reachable` predicate instead of actually probing a
socket, which is the whole reason the selection logic was split out of
instana-forward.py in the first place.
"""

import importlib.machinery
import pathlib
import unittest

DEST = importlib.machinery.SourceFileLoader(
    "instana_destination_under_test",
    str(pathlib.Path(__file__).resolve().parent / "observability" / "instana_destination.py"),
).load_module()


class SchemeProblemTest(unittest.TestCase):
    def test_https_is_always_fine(self):
        self.assertIsNone(DEST.scheme_problem("https://otlp-http-blue-saas.instana.io:443", "INSTANA_ENDPOINT"))

    def test_http_to_loopback_ip_is_the_narrow_exception(self):
        self.assertIsNone(DEST.scheme_problem("http://127.0.0.1:4318", "INSTANA_OTLP_AGENT_ENDPOINT"))

    def test_http_to_localhost_name_is_also_loopback(self):
        self.assertIsNone(DEST.scheme_problem("http://localhost:4318", "INSTANA_OTLP_AGENT_ENDPOINT"))

    def test_http_to_a_real_host_is_still_refused(self):
        problem = DEST.scheme_problem("http://10.0.0.5:4318", "INSTANA_OTLP_AGENT_ENDPOINT")
        self.assertIsNotNone(problem)
        self.assertIn("INSTANA_OTLP_AGENT_ENDPOINT", problem)
        self.assertIn("https", problem)

    def test_http_to_a_real_hostname_is_still_refused(self):
        problem = DEST.scheme_problem("http://otlp.example.com:4318", "INSTANA_OTLP_AGENT_ENDPOINT")
        self.assertIsNotNone(problem)


class ChooseDestinationTest(unittest.TestCase):
    AGENT = "http://127.0.0.1:4318"
    SAAS = "https://otlp-http-blue-saas.instana.io:443"

    def test_agent_preferred_when_reachable_and_both_configured(self):
        dest, problems = DEST.choose_destination(self.AGENT, self.SAAS, False, False, reachable=lambda _: True)
        self.assertEqual(dest.name, "agent")
        self.assertEqual(problems, [])

    def test_falls_back_to_saas_when_agent_unreachable(self):
        dest, problems = DEST.choose_destination(self.AGENT, self.SAAS, False, False, reachable=lambda _: False)
        self.assertEqual(dest.name, "saas")
        self.assertEqual(problems, [])

    def test_neither_available_is_a_problem_not_a_crash(self):
        dest, problems = DEST.choose_destination(self.AGENT, "", False, False, reachable=lambda _: False)
        self.assertEqual(dest.name, "agent")  # still a concrete Destination, for --dry-run
        self.assertTrue(problems)
        self.assertIn("INSTANA_ENDPOINT", problems[0])

    def test_via_agent_forces_agent_even_if_saas_reachable_looking(self):
        dest, problems = DEST.choose_destination(self.AGENT, self.SAAS, True, False, reachable=lambda _: False)
        self.assertEqual(dest.name, "agent")
        self.assertEqual(problems, [])

    def test_via_saas_forces_saas_even_if_agent_reachable(self):
        dest, problems = DEST.choose_destination(self.AGENT, self.SAAS, False, True, reachable=lambda _: True)
        self.assertEqual(dest.name, "saas")
        self.assertEqual(problems, [])

    def test_via_saas_without_endpoint_is_a_problem(self):
        dest, problems = DEST.choose_destination(self.AGENT, "", False, True, reachable=lambda _: True)
        self.assertEqual(dest.name, "saas")
        self.assertTrue(problems)

    def test_both_flags_are_mutually_exclusive(self):
        dest, problems = DEST.choose_destination(self.AGENT, self.SAAS, True, True, reachable=lambda _: True)
        self.assertTrue(problems)
        self.assertIn("mutually exclusive", problems[0])

    def test_agent_destination_never_sends_the_saas_credential(self):
        dest, _ = DEST.choose_destination(self.AGENT, self.SAAS, True, False)
        self.assertFalse(dest.send_key)

    def test_agent_destination_does_not_stamp_host_id_ourselves(self):
        dest, _ = DEST.choose_destination(self.AGENT, self.SAAS, True, False)
        self.assertFalse(dest.stamp_host_id)

    def test_saas_destination_sends_the_credential_and_stamps_host_id(self):
        dest, _ = DEST.choose_destination(self.AGENT, self.SAAS, False, True)
        self.assertTrue(dest.send_key)
        self.assertTrue(dest.stamp_host_id)


if __name__ == "__main__":
    unittest.main()
