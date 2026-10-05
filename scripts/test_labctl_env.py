"""labctl reads station.env itself (it never sources it), and must read each
value the way its writer meant it.

A hand-written free-text value is quoted (`SH_FIXTURE_DESC="..."`) and loses
exactly that pair. `SH_KEY_MAP` is rendered RAW by the registry
(stations_registry.validate_rules.keymap_escape), so a quote at either end is
data: bbcmicro's map starts with `":@` (the BBC's `"` is Shift+2) and ends with
`*:"`, and the old strip-every-quote parser dropped both mappings, so
`labctl type bbcmicro` sent `"` and `*` to their US keys.
"""

import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "labctl.d"))

from common import read_env, unquote_env  # noqa: E402
from keys import key_remap  # noqa: E402

BBC_MAP = "\":@,':&,&:^,(:*,):(,=:_,@:\\,+:%3A,^:=,~:+,_:`,%3A:',*:\""


class TestReadEnv(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        with open(os.path.join(self.dir.name, "station.env"), "w") as fh:
            fh.write(f"SH_FIXTURE_DESC=\"a quoted 'free' text\"\nITS_RE='single'\nSH_KEY_MAP={BBC_MAP}\nPLAIN=x\"y\n")
        self.env = read_env(os.path.join(self.dir.name, "station.env"))

    def test_key_map_is_raw(self):
        self.assertEqual(self.env["SH_KEY_MAP"], BBC_MAP)

    def test_key_remap_keeps_the_quote_mappings(self):
        m = key_remap({"dir": self.dir.name}, "bbcmicro")
        self.assertEqual(m['"'], "@")
        self.assertEqual(m["*"], '"')
        self.assertEqual(m[":"], "'")
        self.assertEqual(m["@"], "\\")
        self.assertEqual(len(m), 13)

    def test_quoted_free_text_loses_one_pair(self):
        self.assertEqual(self.env["SH_FIXTURE_DESC"], "a quoted 'free' text")
        self.assertEqual(self.env["ITS_RE"], "single")

    def test_unmatched_quote_is_data(self):
        self.assertEqual(self.env["PLAIN"], 'x"y')
        self.assertEqual(unquote_env('"abc'), '"abc')
        self.assertEqual(unquote_env("'a\""), "'a\"")
        self.assertEqual(unquote_env('"'), '"')


if __name__ == "__main__":
    unittest.main()
