#!/usr/bin/env python3
"""Tests for the fleet rollout planner.

The wave order and the skip rules are pure functions over a station list, so
they can be pinned down here — before any of it is allowed near a live station.
Everything that touches the box (ssh, systemctl, the framebuffer probe) is
deliberately outside these functions and is not exercised here.
"""

import importlib.machinery
import pathlib
import unittest

ROLLOUT = importlib.machinery.SourceFileLoader(
    "fleet_rollout_under_test",
    str(pathlib.Path(__file__).resolve().parents[0] / "dev" / "fleet_rollout.py"),
).load_module()


def station(sid, reset="loadvm", ui="home-computer", binary=None, source="", retronet=False, backend="", udp=None):
    entry = {
        "id": sid,
        "enabled": True,
        "ui": ui,
        "reset": {"resetMode": reset},
        "emulator": {"source": source},
        "stream": {"transport": "streamhost", "pointer": {"backend": backend}},
    }
    if binary:
        entry["runtime"] = {"qemu": {"binary": binary}}
    if retronet:
        entry["retronet"] = {"planes": ["web"]}
    if udp:
        entry["stream"]["udpPort"] = udp
    return entry


def active(**kw):
    row = {"unit_active": "active", "paused": False, "busy": False, "listening": True}
    row.update(kw)
    return row


class RiskScoreTest(unittest.TestCase):
    def test_snapshot_restore_is_cheaper_than_a_cold_boot(self):
        cheap = ROLLOUT.risk_score(station("a", reset="loadvm"))
        mid = ROLLOUT.risk_score(station("a", reset="relaunch"))
        dear = ROLLOUT.risk_score(station("a", reset="restart"))
        self.assertLess(cheap, mid)
        self.assertLess(mid, dear)

    def test_an_unknown_reset_mode_is_treated_as_the_most_expensive(self):
        self.assertEqual(
            ROLLOUT.risk_score({"reset": {}}),
            ROLLOUT.risk_score(station("a", reset="restart")),
        )

    def test_a_forked_binary_out_of_opt_costs_more_than_a_stock_one(self):
        stock = ROLLOUT.risk_score(station("a"))
        forked = ROLLOUT.risk_score(station("a", binary="/opt/qemu-ppc-s3/bin/qemu-system-ppc"))
        self.assertEqual(forked - stock, 3)

    def test_a_fork_named_only_in_the_emulator_source_still_counts(self):
        self.assertEqual(
            ROLLOUT.risk_score(station("a", source="github.com/Wnt/qemu @ aix432-s3")),
            ROLLOUT.risk_score(station("a", binary="/opt/x")),
        )

    def test_desktop_retronet_and_bespoke_pointer_each_add_risk(self):
        base = ROLLOUT.risk_score(station("a"))
        self.assertEqual(ROLLOUT.risk_score(station("a", ui="desktop")) - base, 2)
        self.assertEqual(ROLLOUT.risk_score(station("a", retronet=True)) - base, 2)
        self.assertEqual(ROLLOUT.risk_score(station("a", backend="mgactl")) - base, 1)

    def test_the_ordinary_pointer_backends_are_not_penalised(self):
        base = ROLLOUT.risk_score(station("a"))
        for backend in ("", "dbus", "qmp", "none", "warpd"):
            self.assertEqual(ROLLOUT.risk_score(station("a", backend=backend)), base, backend)


class OrderTest(unittest.TestCase):
    def setUp(self):
        self.entries = {
            "zx81": station("zx81", reset="relaunch"),
            "helenos": station("helenos", ui="desktop"),
            "aix432": station("aix432", ui="desktop", binary="/opt/q", retronet=True, backend="mgactl"),
            "alpine": station("alpine", ui="text-console"),
        }

    def test_the_safe_tile_goes_first_even_though_it_is_not_the_lowest_score(self):
        order = ROLLOUT.order_stations(self.entries, safe_tile="helenos")
        self.assertEqual(order[0], "helenos")
        self.assertGreater(ROLLOUT.risk_score(self.entries["helenos"]), ROLLOUT.risk_score(self.entries["alpine"]))

    def test_the_most_expensive_station_goes_last(self):
        self.assertEqual(ROLLOUT.order_stations(self.entries, safe_tile="helenos")[-1], "aix432")

    def test_the_order_is_deterministic_across_dict_orderings(self):
        reversed_entries = dict(reversed(list(self.entries.items())))
        self.assertEqual(
            ROLLOUT.order_stations(self.entries, safe_tile="helenos"),
            ROLLOUT.order_stations(reversed_entries, safe_tile="helenos"),
        )


class ClaimTest(unittest.TestCase):
    def test_a_port_claim_on_the_stations_own_udp_slot_matches(self):
        claim = {"class": "port", "name": "54171", "state": "held", "session": "somebody", "purpose": ""}
        self.assertTrue(ROLLOUT.claim_token_match("aix432", claim, udp_port=54171))

    def test_a_port_claim_on_a_different_slot_does_not(self):
        claim = {"class": "port", "name": "54172", "state": "held", "session": "somebody", "purpose": ""}
        self.assertFalse(ROLLOUT.claim_token_match("aix432", claim, udp_port=54171))

    def test_the_station_id_as_a_token_in_the_session_matches(self):
        claim = {"class": "sandbox", "name": "sunos414-abs", "session": "sunos414-abs", "purpose": "x"}
        self.assertTrue(ROLLOUT.claim_token_match("sunos414", claim))

    def test_a_longer_id_that_merely_contains_the_name_does_not_match(self):
        claim = {"class": "sandbox", "name": "amigaos35", "session": "amigaos35", "purpose": ""}
        self.assertFalse(ROLLOUT.claim_token_match("amiga", claim))

    def test_a_walkin_clone_identity_never_claims_the_station_it_is_named_after(self):
        claim = {
            "class": "port",
            "name": "54152",
            "state": "held",
            "session": "osgallery-walkin",
            "purpose": "walkin clone walkin-os2warp-1 @ /data/vms/walkin",
        }
        self.assertFalse(ROLLOUT.claim_token_match("os2warp", claim, udp_port=54108))

    def test_only_held_and_live_claims_park_a_station(self):
        entry = station("beos", udp=54143)
        for state in ("held", "live"):
            claims = [{"class": "sandbox", "name": "beos-abs2", "session": "beos-abs2", "state": state, "purpose": ""}]
            self.assertEqual(ROLLOUT.claim_owner("beos", entry, claims), "beos-abs2", state)
        for state in ("stale", "dead"):
            claims = [{"class": "sandbox", "name": "beos-abs2", "session": "beos-abs2", "state": state, "purpose": ""}]
            self.assertIsNone(ROLLOUT.claim_owner("beos", entry, claims), state)


class ClassifyTest(unittest.TestCase):
    def setUp(self):
        self.entries = {n: station(n) for n in ("a", "b", "c", "d")}
        self.order = ["a", "b", "c", "d"]
        self.state = {n: active() for n in self.order}

    def classify(self, **kw):
        return ROLLOUT.classify(self.entries, self.order, self.state, kw.pop("claims", []), **kw)

    def test_everything_active_and_unclaimed_is_a_target(self):
        targets, skipped = self.classify()
        self.assertEqual(targets, self.order)
        self.assertEqual(skipped, [])

    def test_a_stopped_unit_is_left_alone(self):
        self.state["b"] = active(unit_active="inactive")
        targets, skipped = self.classify()
        self.assertNotIn("b", targets)
        self.assertIn("not active", dict(skipped)["b"])

    def test_a_failed_unit_is_left_alone(self):
        self.state["c"] = active(unit_active="failed")
        targets, skipped = self.classify()
        self.assertNotIn("c", targets)

    def test_a_station_missing_from_the_box_snapshot_is_left_alone(self):
        del self.state["d"]
        targets, skipped = self.classify()
        self.assertNotIn("d", targets)
        self.assertIn("absent", dict(skipped)["d"])

    def test_a_claimed_station_is_skipped_and_names_its_owner(self):
        claims = [{"class": "sandbox", "name": "c", "session": "someone-else", "state": "held", "purpose": ""}]
        targets, skipped = self.classify(claims=claims)
        self.assertNotIn("c", targets)
        self.assertIn("someone-else", dict(skipped)["c"])

    def test_explicit_exclude_wins(self):
        targets, skipped = self.classify(excludes={"a"})
        self.assertEqual(targets, ["b", "c", "d"])
        self.assertEqual(dict(skipped)["a"], "--exclude")

    def test_only_restricts_the_rollout(self):
        targets, skipped = self.classify(only={"b", "d"})
        self.assertEqual(targets, ["b", "d"])
        self.assertEqual(dict(skipped)["a"], "not in --only")

    def test_a_visitor_defers_a_station_by_default(self):
        self.state["a"] = active(busy=True)
        targets, _ = self.classify()
        self.assertNotIn("a", targets)

    def test_include_busy_restarts_it_anyway(self):
        self.state["a"] = active(busy=True)
        targets, _ = self.classify(skip_busy=False)
        self.assertIn("a", targets)

    def test_idle_pause_is_the_normal_resting_state_and_does_not_skip(self):
        # 36 of 71 live stations are paused at any moment; skipping them would
        # roll out nothing at all.
        for name in self.order:
            self.state[name] = active(paused=True)
        targets, skipped = self.classify()
        self.assertEqual(targets, self.order)
        self.assertEqual(skipped, [])

    def test_skip_paused_is_available_when_the_operator_asks(self):
        self.state["b"] = active(paused=True)
        targets, skipped = self.classify(skip_paused=True)
        self.assertNotIn("b", targets)
        self.assertIn("paused", dict(skipped)["b"])

    def test_the_target_order_follows_the_given_order(self):
        targets, _ = ROLLOUT.classify(self.entries, ["d", "c", "b", "a"], self.state, [])
        self.assertEqual(targets, ["d", "c", "b", "a"])


class WaveTest(unittest.TestCase):
    def test_wave_one_is_a_single_station(self):
        waves = ROLLOUT.make_waves(["a", "b", "c", "d", "e"], 2)
        self.assertEqual(waves, [["a"], ["b", "c"], ["d", "e"]])

    def test_canary_first_can_be_turned_off(self):
        waves = ROLLOUT.make_waves(["a", "b", "c", "d"], 2, canary_first=False)
        self.assertEqual(waves, [["a", "b"], ["c", "d"]])

    def test_a_single_station_is_not_split_into_an_empty_wave(self):
        self.assertEqual(ROLLOUT.make_waves(["a"], 4), [["a"]])

    def test_no_wave_ever_exceeds_the_wave_size(self):
        for wave in ROLLOUT.make_waves([str(i) for i in range(61)], 5):
            self.assertLessEqual(len(wave), 5)

    def test_every_station_appears_exactly_once(self):
        stations = [str(i) for i in range(61)]
        flat = [s for wave in ROLLOUT.make_waves(stations, 4) for s in wave]
        self.assertEqual(flat, stations)

    def test_an_empty_plan_makes_no_waves(self):
        self.assertEqual(ROLLOUT.make_waves([], 4), [])

    def test_a_zero_wave_size_is_refused_rather_than_restarting_everything(self):
        with self.assertRaises(ValueError):
            ROLLOUT.make_waves(["a", "b"], 0)


class PromotableTest(unittest.TestCase):
    """build-deploy.sh --promote moves every tile EXCEPT the canary, so a wave
    holding only the canary has nothing for it to do — and handing it that wave
    anyway is what halted the first real rollout at wave 1."""

    def test_the_canary_only_wave_has_nothing_to_promote(self):
        self.assertEqual(ROLLOUT.promotable(["helenos"], "helenos"), [])

    def test_a_mixed_wave_keeps_everything_but_the_canary(self):
        self.assertEqual(ROLLOUT.promotable(["helenos", "alto", "c64"], "helenos"), ["alto", "c64"])

    def test_a_wave_without_the_canary_is_untouched(self):
        self.assertEqual(ROLLOUT.promotable(["alto", "c64"], "helenos"), ["alto", "c64"])

    def test_the_canary_is_whoever_the_gate_names_not_the_safe_tile(self):
        self.assertEqual(ROLLOUT.promotable(["beos", "helenos"], "beos"), ["helenos"])


class FrameFloorTest(unittest.TestCase):
    """A healthy `alpine` login prompt is ~0.4% non-black and failed the flat
    0.5% floor, halting the rollout at wave 2 on a station that was fine."""

    def test_a_text_console_only_has_to_prove_it_is_not_blank(self):
        self.assertEqual(ROLLOUT.min_nonblack_for({"ui": "text-console"}, 0.5), ROLLOUT.CONSOLE_FLOOR)

    def test_a_desktop_keeps_the_strict_floor(self):
        self.assertEqual(ROLLOUT.min_nonblack_for({"ui": "desktop"}, 0.5), 0.5)

    def test_an_unknown_station_keeps_the_strict_floor(self):
        self.assertEqual(ROLLOUT.min_nonblack_for({}, 0.5), 0.5)

    def test_the_console_floor_never_raises_a_lower_operator_floor(self):
        self.assertEqual(ROLLOUT.min_nonblack_for({"ui": "text-console"}, 0.01), 0.01)

    def test_alpines_real_frame_would_now_pass_and_a_black_one_still_fails(self):
        floor = ROLLOUT.min_nonblack_for({"ui": "text-console"}, 0.5)
        self.assertLess(floor, 0.372)
        self.assertGreater(floor, 0.0)


class BeforeAfterFloorTest(unittest.TestCase):
    """mpf2 (`home-computer`, same class as c64 at 61.8% and zxspectrum at
    ~99%) halted a rollout at 0.286% non-black, proving no ui class predicts
    brightness the way alpine (`text-console`) proved one flat percentage
    could not. The honest gate asks whether a station came back to what it
    was, not whether it cleared a fixed number."""

    def test_a_station_stays_healthy_at_its_own_dim_baseline(self):
        before = {"ok": True, "nonblack_pct": 0.286}
        floor = ROLLOUT.effective_floor({"ui": "home-computer"}, before, 0.5)
        self.assertLess(floor, 0.286)

    def test_a_station_that_comes_back_black_fails_its_own_baseline(self):
        before = {"ok": True, "nonblack_pct": 0.286}
        floor = ROLLOUT.effective_floor({"ui": "home-computer"}, before, 0.5)
        self.assertGreater(floor, 0.0)

    def test_the_relative_floor_is_half_the_before_reading(self):
        before = {"ok": True, "nonblack_pct": 40.0}
        self.assertAlmostEqual(ROLLOUT.relative_floor(before), 20.0)

    def test_a_missing_before_frame_falls_back_to_the_class_floor(self):
        self.assertEqual(ROLLOUT.effective_floor({"ui": "text-console"}, None, 0.5), ROLLOUT.CONSOLE_FLOOR)

    def test_a_failed_before_capture_falls_back_to_the_class_floor(self):
        before = {"ok": False, "error": "no framebuffer"}
        self.assertIsNone(ROLLOUT.relative_floor(before))
        self.assertEqual(ROLLOUT.effective_floor({}, before, 0.5), 0.5)

    def test_a_before_frame_that_read_flat_zero_is_not_trusted_as_a_baseline(self):
        # A 0% before-frame is itself indistinguishable from a bad read, and
        # would let a still-0% after-frame pass by "matching its baseline".
        before = {"ok": True, "nonblack_pct": 0.0}
        self.assertIsNone(ROLLOUT.relative_floor(before))
        self.assertEqual(ROLLOUT.effective_floor({}, before, 0.5), 0.5)

    def test_the_relative_floor_never_raises_above_an_explicit_operator_floor(self):
        before = {"ok": True, "nonblack_pct": 96.0}  # a bright desktop before restart
        floor = ROLLOUT.effective_floor({"ui": "desktop"}, before, 0.2)
        self.assertLessEqual(floor, 0.2)

    def test_the_class_floor_and_relative_floor_combine_by_taking_the_lower(self):
        # A dim text-console with an even dimmer before-frame: the relative
        # floor (below CONSOLE_FLOOR) wins over the class floor.
        before = {"ok": True, "nonblack_pct": 0.02}
        floor = ROLLOUT.effective_floor({"ui": "text-console"}, before, 0.5)
        self.assertLess(floor, ROLLOUT.CONSOLE_FLOOR)


class CanaryOrderTest(unittest.TestCase):
    def test_the_gated_canary_leads_the_order_even_when_it_is_not_the_safe_tile(self):
        entries = {"beos": station("beos"), "alto": station("alto"), "c64": station("c64")}
        self.assertEqual(ROLLOUT.order_stations(entries, safe_tile="beos")[0], "beos")


class ResumeTest(unittest.TestCase):
    def test_finished_stations_are_dropped_and_emptied_waves_disappear(self):
        waves = [["a"], ["b", "c"], ["d", "e"]]
        self.assertEqual(ROLLOUT.pending_after_resume(waves, ["a", "b", "c"]), [["d", "e"]])

    def test_a_partly_finished_wave_keeps_only_its_remainder(self):
        waves = [["a"], ["b", "c"], ["d", "e"]]
        self.assertEqual(ROLLOUT.pending_after_resume(waves, ["a", "b"]), [["c"], ["d", "e"]])

    def test_nothing_done_means_nothing_dropped(self):
        waves = [["a"], ["b", "c"]]
        self.assertEqual(ROLLOUT.pending_after_resume(waves, []), waves)

    def test_a_finished_rollout_resumes_into_no_work(self):
        self.assertEqual(ROLLOUT.pending_after_resume([["a"], ["b"]], ["a", "b"]), [])


class RegistryTest(unittest.TestCase):
    """The planner reads the real registry, so its assumptions are checked here."""

    def setUp(self):
        self.entries = ROLLOUT.load_registry()

    def test_the_real_fleet_loads_and_is_the_expected_size(self):
        self.assertGreater(len(self.entries), 50)

    def test_every_loaded_entry_is_an_enabled_streamhost_station(self):
        for sid, entry in self.entries.items():
            self.assertTrue(entry.get("enabled", True), sid)
            self.assertEqual(entry["stream"]["transport"], "streamhost", sid)

    def test_the_safe_tile_is_a_real_station(self):
        self.assertIn(ROLLOUT.SAFE_TILE, self.entries)

    def test_the_real_order_starts_cheap_and_ends_expensive(self):
        order = ROLLOUT.order_stations(self.entries)
        self.assertEqual(order[0], ROLLOUT.SAFE_TILE)
        first_ten = [ROLLOUT.risk_score(self.entries[s]) for s in order[1:11]]
        last_ten = [ROLLOUT.risk_score(self.entries[s]) for s in order[-10:]]
        self.assertLess(max(first_ten), min(last_ten))


if __name__ == "__main__":
    unittest.main()
