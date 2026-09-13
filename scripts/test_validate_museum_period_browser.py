"""`museum.periodBrowser: null` must fail `validate`, not pass it silently.

The SPA's parseEntry (spa/src/data/galleryManifest.ts) does
`typeof entry.periodBrowser === 'string'` with no null case, so a registry
entry carrying `periodBrowser: null` (or missing the key) makes parseEntry
return null for that station -- and vitest, which exercises the manifest end
to end, dies on the missing row. `validate` used to accept null/missing
because it only ever checked *presence* of a handful of museum keys, never
`periodBrowser`'s presence or type. This locks the fix in.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stations_registry.validate_schema import validate_museum_period_browser  # noqa: E402

ROW = {"id": "cand", "_path": "cand"}


def check(museum):
    errors = []
    validate_museum_period_browser(ROW, museum, errors)
    return errors


class Accepts(unittest.TestCase):
    def test_a_real_browser_name(self):
        self.assertEqual(check({"periodBrowser": "NCSA Mosaic"}), [])

    def test_a_none_explanation_is_a_string_not_null(self):
        self.assertEqual(check({"periodBrowser": "none -- pre-web 8-bit era"}), [])


class Refuses(unittest.TestCase):
    def test_null(self):
        errors = check({"periodBrowser": None})
        self.assertTrue(any("periodBrowser" in e and "non-empty string" in e for e in errors), errors)

    def test_missing(self):
        errors = check({})
        self.assertTrue(any("museum missing periodBrowser" in e for e in errors), errors)

    def test_empty_string(self):
        errors = check({"periodBrowser": ""})
        self.assertTrue(any("non-empty string" in e for e in errors), errors)

    def test_whitespace_only(self):
        errors = check({"periodBrowser": "   "})
        self.assertTrue(any("non-empty string" in e for e in errors), errors)

    def test_wrong_type(self):
        errors = check({"periodBrowser": 7})
        self.assertTrue(any("non-empty string" in e for e in errors), errors)


if __name__ == "__main__":
    unittest.main()
