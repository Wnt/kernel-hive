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

import json
import unittest
from pathlib import Path

from . import derive, deviceset, launcher, naming, wake
from . import spec as spec_mod

REPO = Path(__file__).resolve().parents[3]
OS2WARP_LAUNCHER = "streamhost/stations/os2warp/qemu-streamhost.sh"

SPEC_DOC = {
    "station": "os2warp",
    "enabled": True,
    "poolSize": 2,
    "seed": {"disk": "/data/vms/walkin/seeds/os2warp-golden.qcow2", "readOnly": True},
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


class WakeLeaseTests(unittest.TestCase):
    """A resume that is not verified is a resume that did not happen."""

    def setUp(self):
        self.calls = []

    def _execute(self, running_after: int):
        def execute(command, **_):
            self.calls.append(command)
            if command == "query-status":
                return {"running": len([c for c in self.calls if c == "cont"]) >= running_after}
            return {}

        return execute

    def test_a_running_guest_costs_one_query(self):
        wake.wake(self._execute(0), "walkin-os2warp-1")
        self.assertEqual(self.calls, ["query-status"])

    def test_a_paused_guest_is_conted_and_then_proved(self):
        wake.wake(self._execute(1), "walkin-os2warp-1", timeout=2)
        self.assertIn("cont", self.calls)
        self.assertEqual(self.calls[-1], "query-status")

    def test_a_guest_that_never_resumes_raises_rather_than_returning(self):
        # GuestPaused is a RuntimeError, and so is the fallback path's — this
        # passes whether or not guest_wake resolved on this host.
        with self.assertRaises(RuntimeError):
            wake.wake(self._execute(99), "walkin-os2warp-1", timeout=0.3)

    def test_assert_running_refuses_a_re_frozen_guest(self):
        with self.assertRaises(RuntimeError):
            wake.assert_running(lambda command, **_: {"running": False}, "walkin-os2warp-1")

    def test_a_lease_is_always_a_context_manager(self):
        with wake.lease("walkin-os2warp-1"):
            pass


class NeverRunsALauncherTests(unittest.TestCase):
    """The broker DERIVES a clone command line; it never executes a launcher.

    A station launcher hardcodes its own `D=`, its own tap and an unconditional
    `kill "$(cat $D/qemu.pid)"` preamble. Running one for a clone attaches to the
    LIVE station directory and takes the live guest down — measured on rhapsody
    during this wave, and the same shape clone-guard exists for. So the guard is
    structural: the two modules that read a launcher have no way to run one.
    """

    def test_the_parsing_modules_cannot_shell_out(self):
        for module in ("launcher.py", "derive.py"):
            source = (Path(__file__).parent / module).read_text()
            for forbidden in ("import subprocess", "os.system", "os.popen", "check_output"):
                self.assertNotIn(forbidden, source, f"{module} must never execute a station launcher")

    def test_the_kill_preamble_never_reaches_the_command_line(self):
        text = (
            "D=/data/vms/streamhost/stations/os2warp\n"
            '[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")"\n'
            "qemu-system-x86_64 -m 256 -pidfile $D/qemu.pid\n"
        )
        parsed = launcher.parse("live", text=text)
        self.assertNotIn("kill", " ".join(parsed.argv))


class LandedStationFileTests(unittest.TestCase):
    """Every `registry/walkin/*.json` on main must parse. This is the check that
    would have caught win311 landing three schema keys the broker had not met."""

    def test_every_landed_station_file_parses(self):
        files = sorted((REPO / "registry" / "walkin").glob("*.json"))
        self.assertTrue(files, "no walk-in station files found")
        for path in files:
            with self.subTest(station=path.stem):
                loaded = spec_mod.load_spec(path)
                self.assertEqual(loaded.station, path.stem)
                self.assertTrue(loaded.seed_disks)


class SchemaExtensionTests(unittest.TestCase):
    def test_disk_and_disks_are_mutually_exclusive(self):
        for seed in ({"readOnly": True}, {"disk": "/a.qcow2", "disks": ["/b.qcow2"], "readOnly": True}):
            with self.assertRaises(spec_mod.SpecError):
                spec_mod.parse_spec({**SPEC_DOC, "seed": seed}, "test")

    def test_disks_keeps_its_order(self):
        seed = {"disks": ["/seeds/win311-golden.qcow2", "/seeds/games-golden.qcow2"], "readOnly": True}
        parsed = spec_mod.parse_spec({**SPEC_DOC, "seed": seed}, "test")
        self.assertEqual(parsed.seed_disks, ("/seeds/win311-golden.qcow2", "/seeds/games-golden.qcow2"))
        self.assertEqual(parsed.seed_disk, "/seeds/win311-golden.qcow2")

    def test_both_chardev_spellings_mean_the_same_thing(self):
        ledger = {**SPEC_DOC["overrides"], "chardev": {"ser0": "<clone>/serial.sock"}}
        station = {**SPEC_DOC["overrides"], "chardev": {"id": "ser0", "pathPattern": "{stateDir}/serial.sock"}}
        first = spec_mod.parse_spec({**SPEC_DOC, "overrides": ledger}, "test").chardev
        second = spec_mod.parse_spec({**SPEC_DOC, "overrides": station}, "test").chardev
        self.assertEqual(set(first), set(second), "both spellings name the same chardev")

    def test_binary_may_be_declared_at_either_level_but_not_twice_differently(self):
        top = spec_mod.parse_spec({**SPEC_DOC, "binary": "/opt/q/bin/qemu-system-i386"}, "test")
        self.assertEqual(top.binary, "/opt/q/bin/qemu-system-i386")
        doc = {
            **SPEC_DOC,
            "binary": "/opt/a/qemu-system-i386",
            "overrides": {**SPEC_DOC["overrides"], "binary": "/opt/b/qemu-system-i386"},
        }
        with self.assertRaises(spec_mod.SpecError):
            spec_mod.parse_spec(doc, "test")

    def test_invariants_must_be_strings(self):
        with self.assertRaises(spec_mod.SpecError):
            spec_mod.parse_spec({**SPEC_DOC, "invariants": [{"bios": "x"}]}, "test")


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


class BinaryPinTests(unittest.TestCase):
    def test_a_bare_name_asserts_the_launcher_s_own_binary(self):
        spec = a_spec(binary="qemu-system-x86_64")  # what os2warp's launcher runs
        base = derive.read_launcher(spec, REPO)
        derive.derive_argv(base, derive.plan_for(spec, 1, 152), spec)

    def test_a_bare_name_that_disagrees_is_refused_rather_than_substituted(self):
        spec = a_spec(binary="qemu-system-i386")
        base = derive.read_launcher(spec, REPO)
        with self.assertRaises(derive.InvariantError):
            derive.derive_argv(base, derive.plan_for(spec, 1, 152), spec)

    def test_a_missing_pinned_binary_is_refused_rather_than_swapped(self):
        spec = a_spec(overrides={**SPEC_DOC["overrides"], "binary": "/opt/qemu-nowhere/bin/qemu-system-i386"})
        base = derive.read_launcher(spec, REPO)
        plan = derive.plan_for(spec, 1, 152)
        with self.assertRaises(launcher.LauncherError):
            derive.derive_argv(base, plan, spec)

    def test_an_unpinned_binary_may_not_move(self):
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(
                ["qemu-system-x86_64", "-m", "16"], ["/opt/qemu-fork/bin/qemu-system-x86_64", "-m", "16"]
            )

    def test_a_pinned_binary_is_allowed_exactly_once(self):
        pinned = "/opt/qemu-rhapsody/bin/qemu-system-i386"
        deviceset.assert_same_device_set(["qemu-system-i386", "-m", "64"], [pinned, "-m", "64"], expect_binary=pinned)
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(
                ["qemu-system-i386", "-m", "64"], ["qemu-system-i386", "-m", "64"], expect_binary=pinned
            )


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

    def test_an_assignment_is_not_an_invocation(self):
        """rhapsody's shape: the fork is assigned on one line and invoked, via
        the variable, on another. Matching the assignment yields a one-token
        command line that LOOKS parsed — the quietest possible wrong answer."""
        text = (
            "QEMU=/opt/qemu-rhapsody/bin/qemu-system-i386\n"
            "D=/live/rhapsody\n"
            'nohup "$QEMU" \\\n'
            "  -m 64 -drive file=$D/rhapsody-golden.qcow2,format=qcow2,if=ide,index=0 \\\n"
            "  -pidfile $D/qemu.pid\n"
        )
        parsed = launcher.parse("rhap", text=text)
        self.assertEqual(parsed.argv[0], "/opt/qemu-rhapsody/bin/qemu-system-i386")
        self.assertIn("-drive", parsed.argv)

    def test_qemu_img_is_not_an_invocation(self):
        text = (
            "DISK=/live/d.qcow2\n"
            'qemu-img snapshot -l "$DISK" | grep -qw golden\n'
            "qemu-system-x86_64 -m 16 -drive file=$DISK,format=qcow2,if=ide\n"
        )
        self.assertEqual(launcher.parse("img", text=text).argv[0], "qemu-system-x86_64")

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

    def test_a_serial_backend_path_may_move(self):
        # rhapsody's shape: the warpd socket is given straight to -serial rather
        # than through -chardev. The port is the machine type's; the path is not.
        base = ["qemu-system-i386", "-serial", "unix:/live/serial.sock,server=on,wait=off"]
        moved = ["qemu-system-i386", "-serial", "unix:/clone/serial.sock,server=on,wait=off"]
        deviceset.assert_same_device_set(base, moved)
        self.assertEqual(deviceset.signature(base), deviceset.signature(moved))

    def test_a_serial_backend_may_not_be_retyped_or_reoptioned(self):
        base = ["qemu-system-i386", "-serial", "unix:/live/serial.sock,server=on,wait=off"]
        for bad in ("tcp:127.0.0.1:9,server=on,wait=off", "unix:/clone/serial.sock,server=off,wait=off"):
            with self.assertRaises(deviceset.DeviceSetError):
                deviceset.assert_same_device_set(base, ["qemu-system-i386", "-serial", bad])

    def test_a_serial_chardev_id_is_still_the_device_set(self):
        base = ["qemu-system-i386", "-serial", "chardev:ser0"]
        with self.assertRaises(deviceset.DeviceSetError):
            deviceset.assert_same_device_set(base, ["qemu-system-i386", "-serial", "chardev:ser1"])

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

    def test_the_seed_is_replaced_by_the_clone_s_own_copy(self):
        joined = " ".join(self.argv)
        self.assertNotIn(f"file={self.spec.seed_disk}", joined)
        self.assertIn(f"file={self.plan.disks[0]}", joined)
        self.assertEqual(self.plan.disks[0].parent, self.plan.root)

    def test_it_is_instant_ready_and_paused(self):
        self.assertIn("-loadvm", self.argv)
        self.assertIn("-S", self.argv)

    def test_sandbox_flags_are_added(self):
        self.assertIn(derive.SANDBOX_ARG, self.argv)

    def test_the_mac_is_left_alone(self):
        # Ledger §5.3: loadvm restores the NIC address from saved device state,
        # so a per-clone mac= would only make the command line disagree with the
        # vmstate. The pool is one clone per station instead.
        self.assertIn("pcnet,netdev=n0,mac=02:00:00:00:00:13", self.argv)

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


class Win311DerivationTests(unittest.TestCase):
    """The three new schema keys, against the real win311 launcher and file."""

    def setUp(self):
        path = REPO / "registry" / "walkin" / "win311.json"
        if not path.exists():
            self.skipTest("win311 has not landed yet")
        self.spec = spec_mod.load_spec(path)
        self.base = derive.read_launcher(self.spec, REPO)
        self.plan = derive.plan_for(self.spec, 1, 152)
        self.argv = derive.derive_argv(self.base, self.plan, self.spec)

    def test_both_goldens_land_in_the_clone_under_their_own_names(self):
        names = [disk.name for disk in self.plan.disks]
        self.assertEqual(names, ["win311-golden.qcow2", "games-golden.qcow2"])
        joined = " ".join(self.argv)
        for disk in self.plan.disks:
            self.assertIn(f"file={disk}", joined)

    def test_the_second_drive_keeps_its_index(self):
        # index=1 is part of the device set; only file= moved.
        self.assertIn("index=1", " ".join(self.argv))

    def test_the_chardev_backend_moves_and_the_device_set_does_not(self):
        self.assertIn(f"path={self.plan.root}/serial.sock", " ".join(self.argv))
        deviceset.assert_same_device_set(self.base.argv, self.argv, expect_binary=self.argv[0])
        self.assertEqual(deviceset.signature(self.base.argv), deviceset.signature(self.argv))

    def test_the_declared_invariants_survive(self):
        derive.assert_invariants(self.spec, self.argv)
        self.assertIn("-bios", self.argv)

    def test_a_lost_invariant_is_named(self):
        stripped = [tok for tok in self.argv if "bios-256k-int16if.bin" not in tok and tok != "-bios"]
        with self.assertRaises(derive.InvariantError) as caught:
            derive.assert_invariants(self.spec, stripped)
        self.assertIn("bios-256k-int16if.bin", str(caught.exception))

    def test_a_seed_count_that_disagrees_with_the_launcher_is_refused(self):
        doc = json.loads((REPO / "registry" / "walkin" / "win311.json").read_text())
        doc["seed"] = {"disks": [doc["seed"]["disks"][0]], "readOnly": True}
        one_disk = spec_mod.parse_spec(doc, "test")
        with self.assertRaises(derive.InvariantError):
            derive.derive_argv(self.base, derive.plan_for(one_disk, 1, 152), one_disk)

    def test_netdev_id_is_an_assertion_not_a_rename(self):
        doc = json.loads((REPO / "registry" / "walkin" / "win311.json").read_text())
        doc["overrides"]["netdev"]["id"] = "n7"
        renamed = spec_mod.parse_spec(doc, "test")
        with self.assertRaises(deviceset.DeviceSetError):
            derive.derive_argv(self.base, derive.plan_for(renamed, 1, 152), renamed)


if __name__ == "__main__":
    unittest.main()
