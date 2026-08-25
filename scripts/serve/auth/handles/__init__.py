"""Display handles for self-registered walk-in visitors.

`<adj>-<pioneer>` — Docker's `adjective_surname` shape, shortened, and drawn
from computing history instead of a grab-bag of adjectives and scientists:
`bold-turing`, `warm-knuth`, `keen-hopper`, `sly-kay`. The handle is
display-only and carries no authority (see the walk-in contract ledger §4.3);
it exists so a visitor's own clone and any admin view has something readable
to show instead of a raw account id.

Pure function, no I/O, no global state: the caller (the auth store) holds the
lock that makes the `taken` set correct and passes it in. This module never
touches `auth-state.json` itself.
"""

from __future__ import annotations

import random

from .adjectives import ADJECTIVES
from .pioneers import PIONEERS

# Docker-style collision suffixes: -2 through -9. A bare "-1" is never used,
# matching adjective_surname1's own convention.
_MAX_SUFFIX = 9

_SPACE_SIZE = len(ADJECTIVES) * len(PIONEERS)


class HandleSpaceExhausted(Exception):
    """Every `<adj>-<pioneer>` combination, and every -2..-9 suffix of it,
    is already taken. Raised rather than looping forever."""


def generate_handle(taken: set[str], *, rng: random.Random | None = None) -> str:
    """A fresh, unused `<adj>-<pioneer>` handle.

    Random in normal use (the default `rng` is process-global randomness via
    `random.Random()`); deterministic when a caller passes its own seeded
    `random.Random(seed)`, which is how the tests get repeatable sequences
    without reaching into module state.

    `taken` is the full set of handles already in use, lowercase, exactly as
    stored. A collision on the base `<adj>-<pioneer>` form gets a Docker-style
    numeric suffix, `-2` through `-9`; if every suffixed form of every
    combination in the wordlists is taken, `HandleSpaceExhausted` is raised —
    the wordlists need to grow, not the retry loop.
    """
    if rng is None:
        rng = random.Random()

    adjectives = list(ADJECTIVES)
    pioneers = list(PIONEERS)
    rng.shuffle(adjectives)
    rng.shuffle(pioneers)

    for adjective in adjectives:
        for pioneer in pioneers:
            base = f"{adjective}-{pioneer.lower()}"
            if base not in taken:
                return base
            for suffix in range(2, _MAX_SUFFIX + 1):
                candidate = f"{base}-{suffix}"
                if candidate not in taken:
                    return candidate

    raise HandleSpaceExhausted(
        f"no unused handle left in the {_SPACE_SIZE}-combination space "
        f"(x{_MAX_SUFFIX - 1} suffixes each); {len(taken)} handles taken"
    )
