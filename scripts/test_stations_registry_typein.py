"""The type-in editor's registry rules (scripts/stations_registry/validate_typein.py).

Two properties carry the weight: the editor may never be declared faster than
the daemon drains typed keys, and registry/examples/<id>/ content is held to
what the typist can actually key (printable ASCII, the machine's line length)
before it ever reaches a visitor.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stations_registry import validate_typein as vt


def station(os_id: str = "vic20", type_in: dict | None = None, hold: int | None = 60, gap: int | None = 60) -> dict:
    env = {}
    if hold is not None:
        env["SH_KEY_MIN_HOLD_MS"] = str(hold)
    if gap is not None:
        env["SH_KEY_MIN_GAP_MS"] = str(gap)
    row = {"id": os_id, "_path": f"registry/stations/{os_id}.json", "stream": {"transport": "streamhost"}}
    row["runtime"] = {"stationEnv": env}
    if type_in is not None:
        row["typeIn"] = type_in
    return row


def errors_for(rows: list[dict]) -> list[str]:
    errors: list[str] = []
    vt.validate_type_in(rows, errors)
    return errors


class TypeInPacingTest(unittest.TestCase):
    def test_accepts_a_pace_at_or_above_the_drain_rate(self) -> None:
        self.assertEqual(errors_for([station(type_in={"dialect": "cbm-basic", "perCharMs": 120})]), [])
        self.assertEqual(errors_for([station(type_in={"dialect": "cbm-basic", "perCharMs": 170})]), [])

    def test_refuses_a_pace_faster_than_the_daemon_drains(self) -> None:
        errors = errors_for([station(type_in={"dialect": "cbm-basic", "perCharMs": 100})])
        self.assertEqual(len(errors), 1)
        self.assertIn("below the tile's typed drain rate (120 ms/char", errors[0])

    def test_the_modifier_lead_counts_in_the_drain_rate(self) -> None:
        # vic20 ships 60/60 with a 40 ms lead: its worst character costs
        # HOLD + max(GAP, LEAD) + LEAD = 160, which 170 covers and 150 does not.
        def lead(per_char: int, lead_ms: int) -> list[str]:
            row = station(type_in={"dialect": "cbm-basic", "perCharMs": per_char})
            row["runtime"]["stationEnv"]["SH_KEY_MOD_LEAD_MS"] = str(lead_ms)
            return errors_for([row])

        self.assertEqual(lead(170, 40), [])
        errors = lead(150, 40)
        self.assertEqual(len(errors), 1)
        self.assertIn("(160 ms/char", errors[0])
        # a lead longer than the gap replaces it rather than adding to it twice
        self.assertIn("(220 ms/char", lead(200, 80)[0])

    def test_refuses_a_station_whose_drain_rate_is_undeclared(self) -> None:
        errors = errors_for([station(type_in={"dialect": "cbm-basic", "perCharMs": 170}, hold=None, gap=None)])
        self.assertEqual(len(errors), 1)
        self.assertIn("needs a declared drain rate", errors[0])

    def test_refuses_unknown_keys_and_unit_slips(self) -> None:
        errors = errors_for([station(type_in={"dialect": "cbm-basic", "perCharMs": 170000, "speed": 1})])
        self.assertTrue(any("unknown key(s) ['speed']" in e for e in errors))
        self.assertTrue(any("above 2000" in e for e in errors))

    def test_settle_after_and_unreachable_shapes(self) -> None:
        good = {"dialect": "sam-basic", "perCharMs": 170, "settleAfter": {"NEW": 2000}, "unreachable": "<>?"}
        self.assertEqual(errors_for([station(type_in=good)]), [])
        bad = {"dialect": "sam-basic", "perCharMs": 170, "settleAfter": {"new ": 99999}, "unreachable": "<<a"}
        text = "\n".join(errors_for([station(type_in=bad)]))
        self.assertIn("trimmed upper case", text)
        self.assertIn("0..60000", text)
        self.assertIn("never a letter", text)

    def test_enter_after_shape(self) -> None:
        base = {"dialect": "sam-basic", "perCharMs": 170}
        self.assertEqual(errors_for([station(type_in={**base, "enterAfter": ["NEW"]})]), [])
        for bad in ([], ["new"], ["NEW", "NEW"], "NEW", [""], [7]):
            errors = errors_for([station(type_in={**base, "enterAfter": bad})])
            self.assertTrue(any("enterAfter" in e for e in errors), bad)

    def test_wrap_pause_shape(self) -> None:
        base = {"dialect": "applesoft", "perCharMs": 70}
        for good in ({"cols": 40, "ms": 0}, {"cols": 40, "ms": 250, "promptCols": 1}):
            self.assertEqual(errors_for([station(type_in={**base, "wrapPause": good}, hold=32, gap=32)]), [], good)
        for bad in (
            {"cols": 0, "ms": 5},
            {"cols": 40, "ms": -1},
            {"cols": 40},
            {"cols": 40, "ms": 5, "promptCols": 40},
            {"cols": 40, "ms": 5, "extra": 1},
            {"cols": "40", "ms": 5},
            "40",
        ):
            errors = errors_for([station(type_in={**base, "wrapPause": bad}, hold=32, gap=32)])
            self.assertTrue(any("wrapPause" in e for e in errors), bad)

    def test_refuses_a_station_that_does_not_stream(self) -> None:
        row = station(type_in={"dialect": "cbm-basic", "perCharMs": 170})
        row["stream"]["transport"] = "showcase"
        self.assertTrue(any("does not stream" in e for e in errors_for([row])))

    def test_demo_pacing_still_guarded(self) -> None:
        row = station()
        row["demoProgram"] = {"label": "x", "lines": ["10 A=1"], "runCommand": "RUN", "perCharMs": 90}
        errors: list[str] = []
        vt.validate_demo_pacing([row], errors)
        self.assertEqual(len(errors), 1)
        self.assertIn("demoProgram.perCharMs=90", errors[0])


class ExamplesFolderTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self._saved = vt.EXAMPLES
        vt.EXAMPLES = self.root
        self.rows = [station(type_in={"dialect": "cbm-basic", "perCharMs": 170, "maxLineChars": 20}), station("c64")]

    def tearDown(self) -> None:
        vt.EXAMPLES = self._saved
        self._tmp.cleanup()

    def write(self, os_id: str, index: dict, files: dict[str, bytes]) -> None:
        folder = self.root / os_id
        folder.mkdir()
        (folder / "index.json").write_text(json.dumps(index))
        for name, data in files.items():
            (folder / name).write_bytes(data)

    def load(self) -> tuple[dict, list[str]]:
        errors: list[str] = []
        return vt.load_type_in_docs(self.rows, errors), errors

    def test_no_folder_is_no_examples_never_an_error(self) -> None:
        docs, errors = self.load()
        self.assertEqual((dict(docs), errors), ({}, []))

    def test_a_valid_folder_renders_examples_and_manuals(self) -> None:
        self.write(
            "vic20",
            {
                "examples": [{"file": "draw.bas", "kind": "draw", "title": "Lines", "description": "One sentence."}],
                "manuals": [{"title": "User guide", "url": "https://example.com/vic.pdf", "lang": "en"}],
            },
            {"draw.bas": b'10 PRINT "HI"\n20 GOTO 10\n'},
        )
        docs, errors = self.load()
        self.assertEqual(errors, [])
        example = docs["vic20"]["examples"][0]
        self.assertEqual(example["text"], '10 PRINT "HI"\n20 GOTO 10')
        self.assertEqual(example["kind"], "draw")
        self.assertEqual(docs["vic20"]["manuals"][0]["url"], "https://example.com/vic.pdf")

    def test_examples_only_on_editor_stations(self) -> None:
        self.write("c64", {"examples": []}, {})
        _, errors = self.load()
        self.assertEqual(len(errors), 1)
        self.assertIn("station has no typeIn block", errors[0])

    def test_content_the_typist_cannot_key_is_refused(self) -> None:
        self.write(
            "vic20",
            {
                "examples": [
                    {"file": "a.bas", "kind": "game", "title": "A"},
                    {"file": "b.bas", "kind": "game", "title": "B"},
                    {"file": "c.bas", "kind": "game", "title": "C"},
                    {"file": "d.bas", "kind": "dance", "title": "D"},
                ],
                "manuals": [{"title": "M", "url": "http://insecure.example.com/"}],
            },
            {
                "a.bas": "10 PRINT “HI”\n".encode(),
                "b.bas": b"10 PRINT\t1\r\n",
                "c.bas": b"10 PRINT 12345678901234567890\n",
                "d.bas": b"10 END \n",
                "stray.bas": b"10 END\n",
            },
        )
        docs, errors = self.load()
        text = "\n".join(errors)
        self.assertNotIn("vic20", docs)
        self.assertIn("a.bas: not ASCII", text)
        self.assertIn("b.bas:1: only printable ASCII", text)
        self.assertIn("c.bas:1: 29 characters, over this machine's 20-character line", text)
        self.assertIn("'dance' is not one of", text)
        self.assertIn("d.bas:1: trailing spaces", text)
        self.assertIn("stray.bas: not listed in index.json", text)
        self.assertIn("must be an https:// URL", text)

    def test_an_example_may_not_use_a_symbol_the_machine_cannot_reach(self) -> None:
        self.rows[0]["typeIn"]["unreachable"] = "<>"
        self.write(
            "vic20",
            {"examples": [{"file": "a.bas", "kind": "game", "title": "A"}]},
            {"a.bas": b"10 IF A<B THEN 10\n"},
        )
        _, errors = self.load()
        self.assertTrue(any("'<' has no key on this machine" in e for e in errors))

    def test_an_example_may_not_start_with_new_the_editor_types_it(self) -> None:
        self.write(
            "vic20",
            {"examples": [{"file": "a.bas", "kind": "game", "title": "A"}]},
            {"a.bas": b"NEW\n10 PRINT 1\n"},
        )
        _, errors = self.load()
        self.assertTrue(any("a.bas:1: starts with NEW" in e for e in errors))

    def test_a_missing_file_is_named(self) -> None:
        self.write("vic20", {"examples": [{"file": "gone.bas", "kind": "draw", "title": "G"}]}, {})
        _, errors = self.load()
        self.assertTrue(any("'gone.bas' does not exist" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
