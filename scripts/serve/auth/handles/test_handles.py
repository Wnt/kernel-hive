"""Unit tests for the handle generator: python3 -m unittest discover -s scripts/serve/auth/handles"""

from __future__ import annotations

import random
import re
import unittest

from . import HandleSpaceExhausted, generate_handle
from .adjectives import ADJECTIVES
from .pioneers import PIONEERS

_HANDLE_RE = re.compile(r"^[a-z]+-[a-z]+(-[2-9])?$")


class TestWordlists(unittest.TestCase):
    def test_adjectives_are_short_lowercase_and_unique(self):
        self.assertEqual(len(ADJECTIVES), len(set(ADJECTIVES)))
        for word in ADJECTIVES:
            self.assertLessEqual(len(word), 5, word)
            self.assertTrue(word.isalpha() and word.islower(), word)

    def test_pioneers_are_short_titlecase_and_unique(self):
        self.assertEqual(len(PIONEERS), len(set(PIONEERS)))
        for word in PIONEERS:
            self.assertLessEqual(len(word), 7, word)
            self.assertTrue(word.isalpha(), word)
            self.assertEqual(word, word.capitalize(), word)

    def test_wordlists_are_roughly_the_aimed_size(self):
        # The ledger aims ~64 x ~96; hand curation is allowed to land short of
        # that if a word did not clear the "no bad combination" bar.
        self.assertGreaterEqual(len(ADJECTIVES), 48)
        self.assertGreaterEqual(len(PIONEERS), 72)


class TestGenerateHandle(unittest.TestCase):
    def test_shape_is_adjective_dash_pioneer_lowercase(self):
        handle = generate_handle(set(), rng=random.Random(1))
        self.assertRegex(handle, _HANDLE_RE, handle)
        adjective, pioneer = handle.split("-")
        self.assertIn(adjective, ADJECTIVES)
        self.assertIn(pioneer.capitalize(), PIONEERS)

    def test_deterministic_given_a_seed(self):
        first = generate_handle(set(), rng=random.Random(42))
        second = generate_handle(set(), rng=random.Random(42))
        self.assertEqual(first, second)

    def test_different_seeds_usually_differ(self):
        samples = {generate_handle(set(), rng=random.Random(i)) for i in range(20)}
        self.assertGreater(len(samples), 1)

    def test_random_in_normal_use_without_a_seed(self):
        # No rng passed: must not raise, must still be well-formed.
        handle = generate_handle(set())
        self.assertRegex(handle, _HANDLE_RE, handle)

    def test_a_taken_base_form_gets_a_docker_style_suffix(self):
        rng = random.Random(7)
        first = generate_handle(set(), rng=random.Random(7))
        second = generate_handle({first}, rng=rng)
        self.assertNotEqual(first, second)
        base, _, tail = second.rpartition("-")
        # Either a different base pair, or the same base with a -2..-9 suffix.
        if second.startswith(first + "-"):
            self.assertIn(tail, [str(n) for n in range(2, 10)])

    def test_suffixes_climb_2_through_9_before_moving_on(self):
        rng = random.Random(3)
        base = generate_handle(set(), rng=random.Random(3))
        taken = {base}
        for n in range(2, 10):
            taken.add(f"{base}-{n}")
        # Every form of this base is now taken; the next call must not reuse it.
        next_handle = generate_handle(taken, rng=rng)
        self.assertNotIn(next_handle, taken)
        self.assertFalse(next_handle.startswith(base + "-") or next_handle == base)

    def test_never_returns_a_taken_handle_across_many_pulls(self):
        rng = random.Random(1234)
        taken: set[str] = set()
        for _ in range(400):
            handle = generate_handle(taken, rng=rng)
            self.assertNotIn(handle, taken)
            taken.add(handle)
        self.assertEqual(len(taken), 400)

    def test_exhausted_space_raises_instead_of_looping(self):
        taken = set()
        for adjective in ADJECTIVES:
            for pioneer in PIONEERS:
                base = f"{adjective}-{pioneer.lower()}"
                taken.add(base)
                for n in range(2, 10):
                    taken.add(f"{base}-{n}")
        with self.assertRaises(HandleSpaceExhausted):
            generate_handle(taken, rng=random.Random(1))

    def test_pure_function_does_not_mutate_taken(self):
        taken = {"bold-turing"}
        snapshot = set(taken)
        generate_handle(taken, rng=random.Random(9))
        self.assertEqual(taken, snapshot)


if __name__ == "__main__":
    unittest.main()
