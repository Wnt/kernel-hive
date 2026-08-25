"""Unit tests for the walk-in broker: python3 -m unittest discover -s scripts

Nothing here starts a VM. What is worth testing without one is the half that
decides things: the override schema, the command-line derivation, the device-set
refusal (rule 6) and the pool's lifecycle rules — above all that **a clone is
never handed to a second visitor**. The half that needs a hypervisor is proved on
the box, at the framebuffer (rule 9).

The derivation tests run against the REAL `os2warp` launcher in the repo rather
than a fixture, because a fixture is exactly the fork the brief forbids: it would
keep passing after the station's launcher changed underneath it.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from . import broker as broker_mod
from . import derive, deviceset, launcher, naming
from . import spec as spec_mod

REPO = Path(__file__).resolve().parents[3]
OS2WARP_LAUNCHER = "streamhost/stations/os2warp/qemu-streamhost.sh"

SPEC_DOC = {
    "station": "os2warp",
    "enabled": True,
    "poolSize": 2,
    "seed": {"disk": "/data/gallery-guests/OS2Warp/os2.qcow2", "readOnly": True},
    "overlay": {"format": "qcow2", "discardOnKill": True},
    "launcher": OS2WARP_LAUNCHER,
    "overrides": {"netdev": {"type": "tap", "bridge": "vmbr-wi", "ifnamePattern": "wi-os2warp-%d"}, "tapnet": "x.sh"},
    "sandbox": True,
}


def a_spec(**over) -> spec_mod.StationSpec:
    doc = {**SPEC_DOC, **over}
    return spec_mod.parse_spec(doc, "test")


class SpecTests(unittest.TestCase):
    def test_unknown_key_is_an_error(self):
        with self.assertRaises(spec_mod.SpecError):
            spec_mod.parse_spec({**SPEC_DOC, "poolsize": 3}, "test")

    def test_unknown_override_key_is_an_error(self):
        doc = {**SPEC_DOC, "overrides": {**SPEC_DOC["overrides"], "device": "-device usb-tablet"}}
        with self.assertRaises(spec_mod.SpecError):
            spec_mod.parse_spec(doc, "test")

    def test_writable_seed_is_refused(self):
        with self.assertRaises(spec_mod.SpecError):
            spec_mod.parse_spec({**SPEC_DOC, "seed": {"disk": "/x.qcow2", "readOnly": False}}, "test")

    def test_tap_without_a_tapnet_script_is_refused(self):
        doc = {**SPEC_DOC, "overrides": {"netdev": {"type": "tap"}}}
        with self.assertRaises(spec_mod.SpecError):
            spec_mod.parse_spec(doc, "test")

    def test_ifname_pattern_needs_the_index(self):
        doc = {**SPEC_DOC, "overrides": {"netdev": {"type": "tap", "ifnamePattern": "wi-os2"}, "tapnet": "x.sh"}}
        with self.assertRaises(spec_mod.SpecError):
            spec_mod.parse_spec(doc, "test")


class NamingTests(unittest.TestCase):
    def test_slot_range_is_the_ledger_range(self):
        self.assertEqual((naming.SLOT_MIN, naming.SLOT_MAX), (152, 200))
        with self.assertRaises(naming.NameError_):
            naming.check_slot(151)
        with self.assertRaises(naming.NameError_):
            naming.check_slot(201)

    def test_port_and_identity(self):
        self.assertEqual(naming.udp_port(152), 54152)
        self.assertEqual(naming.identity("os2warp", 3), "walkin-os2warp-3")
        self.assertEqual(naming.clone_mac(152), "02:00:00:00:57:98")

    def test_tap_name_respects_the_kernel_limit(self):
        with self.assertRaises(naming.NameError_):
            naming.tap_name("os2warp", 3, "wi-averylongname-%d")


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.parsed = launcher.parse(
            REPO / OS2WARP_LAUNCHER,
            presets={"B": str(REPO / "streamhost/stations/os2warp"), "LOADVM": "-loadvm golden -S"},
        )

    def test_reads_the_stations_own_command_line(self):
        self.assertEqual(self.parsed.binary, "qemu-system-x86_64")
        self.assertIn("-device", self.parsed.argv)
        self.assertIn("pcnet,netdev=n0,mac=02:00:00:00:00:13", self.parsed.argv)

    def test_finds_the_tap_script(self):
        self.assertTrue(self.parsed.tapnet.endswith("rn-tapnet.sh"))

    def test_unresolvable_variable_is_loud(self):
        with self.assertRaises(launcher.LauncherError):
            launcher.parse("mem", text="qemu-system-x86_64 -m $MYSTERY\n")

    def test_two_invocations_are_refused(self):
        text = "qemu-system-x86_64 -m 16\nqemu-system-x86_64 -m 32\n"
        with self.assertRaises(launcher.LauncherError):
            launcher.parse("two", text=text)

    def test_no_qemu_at_all_is_refused(self):
        with self.assertRaises(launcher.LauncherError):
            launcher.parse("none", text="mame -rp roms nws3260\n")


class DeviceSetTests(unittest.TestCase):
    BASE = [
        "qemu-system-x86_64", "-m", "256", "-vga", "std",
        "-drive", "file=/seed.qcow2,format=qcow2,if=ide",
        "-netdev", "tap,id=n0,ifname=os2rn0,script=no,downscript=no",
        "-device", "pcnet,netdev=n0,mac=02:00:00:00:00:13",
        "-pidfile", "/live/qemu.pid",
    ]  # fmt: skip

    def derived(self, *changes):
        out = list(self.BASE)
        for index, value in changes:
            out[index] = value
        return out

    def test_paths_ports_taps_and_macs_are_allowed(self):
        ok = self.derived(
            (6, "file=/clone/overlay.qcow2,format=qcow2,if=ide"),
            (8, "tap,id=n0,ifname=wi-os2warp-1,script=no,downscript=no"),
            (10, "pcnet,netdev=n0,mac=02:00:00:00:57:98"),
            (12, "/data/vms/walkin/walkin-os2warp-1/qemu.pid"),
        )
        deviceset.assert_same_device_set(self.BASE, ok)

    def test_netdev_backend_may_be_retyped(self):
        deviceset.assert_same_device_set(self.BASE, self.derived((8, "user,id=n0,restrict=on")))

    def test_netdev_id_may_not_change(self):
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(self.BASE, self.derived((8, "user,id=n1,restrict=on")))

    def test_added_device_is_refused(self):
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(self.BASE, self.BASE + ["-device", "usb-tablet"])

    def test_removed_device_is_refused(self):
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(self.BASE, self.BASE[:9])

    def test_retyped_device_is_refused(self):
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(self.BASE, self.derived((10, "e1000,netdev=n0,mac=02:00:00:00:00:13")))

    def test_machine_shape_may_not_change(self):
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(self.BASE, self.derived((2, "512")))
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(self.BASE, self.derived((4, "cirrus")))

    def test_drive_interface_may_not_change(self):
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(self.BASE, self.derived((6, "file=/seed.qcow2,format=qcow2,if=virtio")))

    def test_binary_may_not_change(self):
        swapped = ["qemu-system-i386"] + self.BASE[1:]
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(self.BASE, swapped)


class DeriveTests(unittest.TestCase):
    def setUp(self):
        self.spec = a_spec()
        self.base = derive.read_launcher(self.spec, REPO)
        self.plan = derive.plan_for(self.spec, 1, 152)
        self.argv = derive.derive_argv(self.base, self.plan, self.spec)

    def test_command_line_is_re_rooted_into_the_clone(self):
        joined = " ".join(self.argv)
        self.assertNotIn("/data/vms/streamhost/stations/os2warp", joined)
        self.assertIn("/data/vms/walkin/walkin-os2warp-1/qemu.pid", self.argv)
        self.assertIn("path=/data/vms/walkin/walkin-os2warp-1/serial.sock", joined)

    def test_the_seed_is_replaced_by_the_overlay(self):
        joined = " ".join(self.argv)
        self.assertNotIn(self.spec.seed_disk, joined)
        self.assertIn("overlay.qcow2", joined)

    def test_it_is_instant_ready_and_paused(self):
        self.assertIn("-loadvm", self.argv)
        self.assertIn("-S", self.argv)

    def test_sandbox_flags_are_added(self):
        self.assertIn(derive.SANDBOX_ARG, self.argv)

    def test_the_device_set_is_untouched(self):
        self.assertEqual(deviceset.signature(self.base.argv), deviceset.signature(self.argv))

    def test_a_device_changing_override_cannot_get_through(self):
        text = (
            "D=/live/os2warp\n"
            "qemu-system-x86_64 -m 256 -vga std \\\n"
            "  -drive file=/seed.qcow2,format=qcow2,if=ide \\\n"
            "  -netdev tap,id=n0,ifname=os2rn0 -device pcnet,netdev=n0 \\\n"
            "  -pidfile $D/qemu.pid\n"
        )
        base = launcher.parse("fake", text=text)
        # A malicious/mistaken derivation that adds a device must be refused by
        # the check, not by whoever notices the golden stopped restoring.
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(base.argv, base.argv + ["-device", "usb-tablet"])


class FakeClone:
    """A pool member with no hypervisor behind it."""

    def __init__(self, spec, index):
        self.spec = spec
        self.plan = derive.plan_for(spec, index, naming.SLOT_MIN + index - 1)
        self.destroyed = False
        self._alive = True

    @property
    def identity(self):
        return self.plan.identity

    def destroy(self):
        self.destroyed = True
        self._alive = False

    def alive(self):
        return self._alive

    def resume(self):
        pass


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.clock = [1000.0]
        self.made = []

        def factory(spec, index):
            made = FakeClone(spec, index)
            self.made.append(made)
            return made

        self.broker = broker_mod.Broker(
            REPO / "does-not-exist", REPO, now=lambda: self.clock[0], spawn=False, factory=factory
        )
        self.broker.specs = {"os2warp": a_spec()}
        self.broker.set_access("open")

    def test_pool_is_warm(self):
        self.assertEqual(self.broker.state()["pools"], [{"os": "os2warp", "free": 2, "size": 2}])

    def test_claim_takes_a_member_out_of_the_pool(self):
        got = self.broker.claim("u1", "os2warp")
        self.assertTrue(got["clone"].startswith("walkin-os2warp-"))
        self.assertEqual(got["signalEndpoint"], f"/signal/{got['clone']}.json")
        self.assertEqual(got["ttlSeconds"], broker_mod.TTL_SECONDS)
        self.assertEqual(self.broker.state()["pools"][0]["free"], 1)

    def test_a_clone_is_never_handed_to_a_second_visitor(self):
        first = self.broker.claim("u1", "os2warp")["clone"]
        self.broker.release("u1", first)
        seen = {first}
        for user in ("u2", "u3", "u4"):
            got = self.broker.claim(user, "os2warp")["clone"]
            self.assertNotIn(got, seen)
            seen.add(got)
            self.broker.release(user, got)
        self.assertTrue(all(c.destroyed for c in self.made if c.identity in seen))

    def test_release_refuses_someone_elses_clone(self):
        mine = self.broker.claim("u1", "os2warp")["clone"]
        with self.assertRaises(broker_mod.BrokerError):
            self.broker.release("u2", mine)

    def test_ttl_ends_the_session_with_its_reason_code(self):
        self.broker.claim("u1", "os2warp")
        self.clock[0] += broker_mod.TTL_SECONDS + 1
        report = self.broker.tick()
        self.assertEqual([code for _, code in report["ended"]], [broker_mod.CLOSE_REASON_TTL])
        self.assertEqual(self.broker.close_reason("u1"), "WALKIN_TTL")

    def test_idle_ends_the_session_early(self):
        clone = self.broker.claim("u1", "os2warp")["clone"]
        self.clock[0] += broker_mod.IDLE_SECONDS - 1
        self.broker.note_input(clone)
        self.clock[0] += broker_mod.IDLE_SECONDS - 1
        self.assertEqual(self.broker.tick()["ended"], [])
        self.clock[0] += 2
        self.assertEqual(self.broker.close_reason("u1"), "")
        self.broker.tick()
        self.assertEqual(self.broker.close_reason("u1"), "WALKIN_IDLE")

    def test_closing_disconnects_everyone_and_empties_the_pool(self):
        self.broker.claim("u1", "os2warp")
        disconnected = self.broker.set_access("closed")
        self.assertEqual(disconnected, 1)
        self.assertEqual(self.broker.state()["pools"], [{"os": "os2warp", "free": 0, "size": 2}])
        self.assertEqual(self.broker.close_reason("u1"), "WALKIN_CLOSED")
        self.assertTrue(all(c.destroyed for c in self.made))

    def test_claim_while_closed_is_refused(self):
        self.broker.set_access("closed")
        with self.assertRaises(broker_mod.BrokerError) as caught:
            self.broker.claim("u9", "os2warp")
        self.assertEqual(str(caught.exception), "walkin_closed")

    def test_reopening_refills_the_pool(self):
        self.broker.set_access("closed")
        self.broker.set_access("invited")
        self.assertEqual(self.broker.state()["pools"][0]["free"], 2)

    def test_a_queued_visitor_gets_a_position(self):
        self.broker.claim("u1", "os2warp")
        self.broker.claim("u2", "os2warp")
        queued = self.broker.claim("u3", "os2warp")
        self.assertEqual(queued, {"queued": True, "position": 1})

    def test_one_session_per_account(self):
        self.broker.claim("u1", "os2warp")
        with self.assertRaises(broker_mod.BrokerError):
            self.broker.claim("u1", "os2warp")

    def test_reset_gives_a_different_machine(self):
        first = self.broker.claim("u1", "os2warp")["clone"]
        second = self.broker.reset("u1", first)["clone"]
        self.assertNotEqual(first, second)

    def test_extension_is_refused_while_someone_waits(self):
        first = self.broker.claim("u1", "os2warp")["clone"]
        self.broker.claim("u2", "os2warp")
        self.broker.claim("u3", "os2warp")  # queues
        self.assertEqual(self.broker.extend("u1", first), broker_mod.TTL_SECONDS)

    def test_a_dead_pool_member_is_reaped(self):
        victim = self.made[0]
        victim._alive = False
        self.assertIn(victim.identity, self.broker.tick()["died"])

    def test_signal_entries_describe_the_pool(self):
        entries = self.broker.signal_entries()
        self.assertEqual(len(entries), 2)
        for name, row in entries.items():
            self.assertTrue(name.startswith("walkin-os2warp-"))
            self.assertGreaterEqual(row["udpPort"], 54152)


if __name__ == "__main__":
    unittest.main()
