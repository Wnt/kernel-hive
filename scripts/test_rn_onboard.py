"""rn-onboard's two load-bearing behaviours, tested without the box.

The first is the refusal: this tool is the only thing standing between an
allocated MAC and a public repository, and a refusal nobody exercises is a
comment. The second is the rendering: one template now defines the retronet's
containment for every station, so a substitution bug is a fleet-wide
containment bug rather than a typo in one file.
"""

import importlib.util
import json
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("rn_onboard_lib", REPO / "scripts/retronet/rn_onboard_lib.py")
lib = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lib)

TEMPLATE_TAP = REPO / "scripts/retronet/rn-tapnet.template.sh"
TEMPLATE_DOC = REPO / "scripts/retronet/rn-station-doc.template.md"
REAL_MAC = "52:54:00:52:4e:1d"


def tokens(station="pcbsd", address="10.99.0.29", mac=REAL_MAC, **kw):
    return lib.tokens_for(station, address, mac, uin="17900", date="2026-09-03", **kw)


class Naming(unittest.TestCase):
    def test_scheme(self):
        self.assertEqual(lib.tap_name("pcbsd"), "pcbsdrn0")
        self.assertEqual(lib.chain_name("pcbsd"), "PCBSDRN-IN")
        self.assertEqual(lib.chain_name("netbsd14"), "NETBSD14RN-IN")
        self.assertEqual(lib.env_key("suse64", "mac"), "RN_SUSE64_MAC")
        self.assertEqual(lib.env_key("suse64", "pass"), "RETRONET_ICQ_SUSE64_PASS")

    def test_matches_the_stations_already_on_the_plane(self):
        """The template must reproduce the names the live fleet already uses."""
        for station in ("pcbsd", "suse64", "slackware", "ubuntu", "netbsd14"):
            row = json.loads((REPO / "registry/stations" / f"{station}.json").read_text())
            block = row["retronet"]
            self.assertEqual(block["link"], f"tap {lib.tap_name(station)} on vmbr-rn", station)
            self.assertEqual(block["guard"], lib.chain_name(station), station)

    def test_over_long_names_are_caught_before_the_kernel_truncates_them(self):
        problems = lib.check_names("averylongstationname")
        self.assertTrue(any("IFNAMSIZ" in p for p in problems), problems)

    def test_station_id_must_be_a_station_id(self):
        self.assertTrue(lib.check_names("PCBSD"))
        self.assertFalse(lib.check_names("pcbsd"))


class Addresses(unittest.TestCase):
    def test_plane_membership(self):
        self.assertEqual(lib.check_address("10.99.0.29"), [])
        self.assertTrue(lib.check_address("192.168.1.29"))

    def test_infrastructure_addresses_are_refused(self):
        for taken in ("10.99.0.1", "10.99.0.2", "10.99.0.0", "10.99.0.255"):
            self.assertTrue(lib.check_address(taken), taken)

    def test_the_dhcp_pool_is_not_allocatable(self):
        self.assertTrue(lib.check_address("10.99.0.101"))

    def test_fleet_mac_scheme(self):
        self.assertEqual(lib.expected_mac("10.99.0.29"), "52:54:00:52:4e:1d")
        self.assertEqual(lib.expected_mac("10.99.0.37"), "52:54:00:52:4e:25")


class PlaceholderRefusal(unittest.TestCase):
    def test_a_real_mac_is_refused(self):
        problems = lib.check_committable(f"mac={REAL_MAC}", "launcher")
        self.assertEqual(len(problems), 1)
        self.assertIn("02:00:00:00:00:1d", problems[0])

    def test_the_scrubbed_mac_is_accepted(self):
        self.assertEqual(lib.check_committable("mac=02:00:00:00:00:1d", "launcher"), [])

    def test_case_does_not_launder_a_mac(self):
        self.assertTrue(lib.check_committable("MAC=52:54:00:52:4E:1D", "launcher"))

    def test_scrubbing_keeps_only_the_last_octet(self):
        self.assertEqual(lib.placeholder_mac(REAL_MAC), "02:00:00:00:00:1d")

    def test_the_retronet_plane_is_committable_on_purpose(self):
        """10.99.0.x is the committed half of the uniqueness ledger."""
        self.assertEqual(lib.check_committable("addr 10.99.0.29 gw 10.99.0.2 slirp 10.0.2.15", "x"), [])

    def test_a_lan_address_is_refused(self):
        problems = lib.check_committable("ssh 192.168.7.4", "doc")
        self.assertEqual(len(problems), 1)
        self.assertIn("192.0.2.x", problems[0])

    def test_the_scrubbed_documentation_range_is_accepted(self):
        self.assertEqual(lib.check_committable("host 192.0.2.10", "doc"), [])


class Passwords(unittest.TestCase):
    def test_generated_passwords_satisfy_the_gateway(self):
        for _ in range(20):
            self.assertEqual(lib.check_password(lib.generate_password()), [])

    def test_the_gateway_length_limit(self):
        self.assertTrue(lib.check_password("abcdefghi"))
        self.assertTrue(lib.check_password("abc"))

    def test_characters_era_clients_mangle(self):
        self.assertTrue(lib.check_password("ab!def"))


class Rendering(unittest.TestCase):
    def setUp(self):
        self.tap = lib.render(TEMPLATE_TAP.read_text(), tokens(), "rn-tapnet.sh")
        self.doc = lib.render(TEMPLATE_DOC.read_text(), tokens(), "STATION-pcbsd.md")

    def test_every_token_is_consumed(self):
        for text in (self.tap, self.doc):
            self.assertNotIn("@", text.replace("@ID@", ""), "a token survived rendering")

    def test_the_template_only_block_is_stripped(self):
        for text in (self.tap, self.doc):
            self.assertNotIn("template-only", text)
        self.assertNotIn("rn-tapnet.template.sh — the ONE source", self.tap)

    def test_the_rendered_script_is_still_a_script(self):
        self.assertTrue(self.tap.startswith("#!/bin/bash\n"))
        for needle in ('IF="${RN_TAP_IF:-pcbsdrn0}"', 'IN_CHAIN="${RN_TAP_IN_CHAIN:-PCBSDRN-IN}"', "10.99.0.29"):
            self.assertIn(needle, self.tap)

    def test_the_rendered_script_carries_only_the_placeholder_mac(self):
        self.assertIn("02:00:00:00:00:1d", self.tap)
        self.assertNotIn(REAL_MAC, self.tap)
        self.assertIn("RN_PCBSD_MAC", self.tap)

    def test_containment_is_hooked_on_both_the_ip_and_the_mac(self):
        """The beos lesson: an IP-scoped chain stops containing a guest that
        lands on a pool address instead of its reservation."""
        self.assertIn('-s "$GUEST_IP" -j "$IN_CHAIN"', self.tap)
        self.assertIn('--mac-source "$GUEST_MAC" -j "$IN_CHAIN"', self.tap)

    def test_the_guard_is_read_back_out_of_the_kernel(self):
        self.assertIn("did not verify — refusing to report up", self.tap)

    def test_rendering_refuses_a_real_address_in_the_output(self):
        with self.assertRaises(ValueError) as caught:
            lib.render("host is 203.0.113.9 and 172.16.4.4\n", {}, "x")
        self.assertIn("172.16.4.4", str(caught.exception))

    def test_an_unsubstituted_token_is_an_error_not_a_silent_pass(self):
        with self.assertRaises(ValueError) as caught:
            lib.render("tap is @TAP@\n", {"@ID@": "x"}, "x")
        self.assertIn("@TAP@", str(caught.exception))


class RegistryAndRoster(unittest.TestCase):
    def test_block_matches_the_landed_stations_byte_for_byte(self):
        for station in ("pcbsd", "suse64", "ubuntu", "slackware", "netbsd14"):
            row = json.loads((REPO / "registry/stations" / f"{station}.json").read_text())
            block = row["retronet"]
            built = lib.registry_block(
                station,
                block["address"],
                planes=block["planes"],
                addressing=block["addressing"],
                joined=block["joined"],
            )
            self.assertEqual(built, block, station)

    def test_the_block_round_trips_at_the_registry_indent(self):
        path = REPO / "registry/stations/pcbsd.json"
        row = json.loads(path.read_text())
        self.assertEqual(json.dumps(row, indent=1, ensure_ascii=False) + "\n", path.read_text())

    def test_roster_row_starts_unproven(self):
        row = lib.roster_row("pcbsd", "17900", "kopete012")
        self.assertIs(row["onboarded"], False)
        self.assertEqual(row["nick"], "pcbsd")

    def test_roster_insert_is_idempotent_and_keeps_a_proven_flag(self):
        roster = {"stations": [{"station": "pcbsd", "uin": "17900", "nick": "pcbsd", "client": "k", "onboarded": True}]}
        out = lib.insert_roster_row(roster, lib.roster_row("pcbsd", "17900", "kopete012"))
        self.assertEqual(len(out["stations"]), 1)
        self.assertIs(out["stations"][0]["onboarded"], True)
        self.assertEqual(out["stations"][0]["client"], "kopete012")

    def test_a_duplicate_uin_is_refused(self):
        row = {"station": "suse64", "uin": "18000", "nick": "suse64", "client": "g", "onboarded": True}
        roster = {"stations": [row]}
        with self.assertRaises(ValueError):
            lib.insert_roster_row(roster, lib.roster_row("pcbsd", "18000", "kopete012"))

    def test_the_live_roster_still_loads_after_an_insert(self):
        roster = json.loads((REPO / "scripts/retronet/icq/roster.json").read_text())
        out = lib.insert_roster_row(roster, lib.roster_row("kh-test", "19999", "gaim0599"))
        self.assertEqual(len(out["stations"]), len(roster["stations"]) + 1)


class LocalEnvAndGateway(unittest.TestCase):
    def test_one_append_carries_both_values(self):
        text = lib.local_env_append("pcbsd", REAL_MAC, "abc12345")
        self.assertIn(f"RN_PCBSD_MAC={REAL_MAC}", text)
        self.assertIn("RETRONET_ICQ_PCBSD_PASS=abc12345", text)
        self.assertTrue(text.endswith("\n"))

    def test_a_placeholder_mac_is_not_written_to_local_env(self):
        text = lib.local_env_append("pcbsd", "02:00:00:00:00:1d", None)
        self.assertNotIn("RN_PCBSD_MAC", text)

    def test_the_append_never_touches_the_reservation_ledger(self):
        """RETRONET_DHCP_RESERVATIONS is ONE variable; a second assignment shadows it."""
        self.assertNotIn("RESERVATIONS", lib.local_env_append("pcbsd", REAL_MAC, "abc12345"))

    def test_the_account_is_opened_for_unattended_contacts(self):
        cmds = lib.gateway_commands("17900", "pcbsd", "abc12345")
        verbs = [c[c.index("/opt/ras/rn-tool.py") + 1] for c in cmds]
        self.assertEqual(verbs, ["user-set", "user-open", "nick", "ssi-seed"])
        self.assertIn("10000=HiveBot", cmds[-1])


if __name__ == "__main__":
    unittest.main()
