"""The labctl exec declarations a station makes must survive to the box.

A key that a station file sets but `LABCTL_KEYS` does not list is dropped
SILENTLY on its way to `labctl-declarations.json` -> `labctl gen` ->
`stations.json`. beos paid for that once with `exec_shell`: every command
returned the right output and rc -1. aix432 would pay for it again with
`exec_subshell`: every command right, and a bare `exit N` reported as a
channel fault instead of N.

These are cheap guards on that whole path, from the two ends that are files.
"""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stations_registry.constants import LABCTL_KEYS  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATIONS = os.path.join(REPO, "registry", "stations")
DECLARATIONS = os.path.join(REPO, "registry", "generated", "labctl-declarations.json")


def _labctl(station):
    """A station's operator.labctl block, or {} — posters have no operator at all."""
    with open(os.path.join(STATIONS, station + ".json")) as fh:
        return json.load(fh).get("operator", {}).get("labctl") or {}


class TestLabctlKeysAllowlist(unittest.TestCase):
    def test_every_declared_key_is_in_the_allowlist(self):
        """No station may set a labctl key the generator will drop."""
        for name in sorted(os.listdir(STATIONS)):
            if not name.endswith(".json"):
                continue
            station = name[:-5]
            for key in _labctl(station):
                self.assertIn(
                    key,
                    LABCTL_KEYS,
                    f"{station} declares operator.labctl.{key}, which is NOT in "
                    "LABCTL_KEYS and would be dropped silently on its way to the box",
                )

    def test_declared_keys_reach_the_generated_declarations(self):
        with open(DECLARATIONS) as fh:
            gen = json.load(fh)
        # The generated file is the contract labctl gen reads; a key present in
        # a station file must be present, with the same value, in there.
        for station, declared in (("aix432", _labctl("aix432")), ("beos", _labctl("beos"))):
            got = gen["tiles"][station] if "tiles" in gen else gen[station]
            for key, value in declared.items():
                self.assertEqual(
                    got.get(key),
                    value,
                    f"{station}.{key}: registry says {value!r}, generated declarations "
                    f"say {got.get(key)!r} (run `make station-registry-generate`)",
                )


class TestAix432ExecChannel(unittest.TestCase):
    """The three fields that make `labctl exec aix432` behave, and one that must not appear."""

    def setUp(self):
        self.c = _labctl("aix432")

    def test_telnet_unix_e_on_the_retronet_address(self):
        self.assertEqual(self.c["exec_kind"], "telnet_unix_e")
        self.assertEqual(self.c["exec_port"], 23)
        self.assertEqual(self.c["exec_host"], "10.99.0.28")

    def test_ksh_spells_the_exit_code_with_dollar_question(self):
        # Absent/other means csh's $status, which reports rc -1 on every call
        # while the output looks perfect.
        self.assertEqual(self.c["exec_shell"], "sh")

    def test_subshell_is_on_so_a_bare_exit_is_not_a_channel_fault(self):
        # AIX's ksh IS the login shell: `exit 3` without the ( ) wrap ends the
        # session mid-marker and surfaces as a traceback with rc 1.
        self.assertIs(self.c["exec_subshell"], True)

    def test_no_password_in_the_committed_registry(self):
        # It is republished by the launcher from the gitignored local.env into
        # <station dir>/telnet-exec.passwd, mode 0600.
        self.assertNotIn("exec_pass", self.c)
        self.assertNotIn("exec_password", self.c)


if __name__ == "__main__":
    unittest.main()
