"""Pull the walk-in broker suite into the canonical gate run.

`scripts/` and `scripts/serve/` are not packages, and unittest discovery has
not descended into non-package directories since Python 3.11. So
`python3 -m unittest discover -s scripts -p 'test_*.py'` — the command
docs/lab/AGENT-CI-EXIT-RULE.md calls canonical and the one
`.github/workflows/quality.yml` actually runs — walked straight past every test
under `scripts/serve/**`. The whole broker suite, 183 tests covering the pool's
founding invariant, the anonymous budget, the conversion wall and (2026-09-15)
the switch hold, ran only when somebody remembered to `cd scripts/serve` by
hand. `scripts/test_walkin_smoke_taps.py` noted the hole in its own docstring;
this file is the fix, using the `load_tests` protocol so discovery adopts the
sub-suite instead of needing `scripts/` to become a package.

**`auth/` is deliberately NOT here.** It imports `fido2` (`auth/passkeys.py`),
which CI installs no wheel for — quality.yml's only `pip install` is Pillow —
so adopting it would turn the gate red on a missing dependency rather than on
anything anyone wrote. `walkin/` imports nothing outside the standard library,
which is what makes it safe to adopt unconditionally. Wiring `auth/` in needs
`fido2` added to the workflow first; until then that suite is still run by hand.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVE = ROOT / "scripts" / "serve"
#: Sub-packages of `scripts/serve/` whose tests the gate adopts. See the header
#: for why `auth` is not one of them.
ADOPTED = ("walkin",)


def load_tests(loader, tests, pattern):  # noqa: ARG001 - the unittest protocol's shape
    """Discovery calls this; whatever it returns replaces this module's tests."""
    if str(SERVE) not in sys.path:
        # The suites import each other as `from . import broker`, so they must be
        # loaded AS the package they live in — `serve/` on the path, not this
        # file's. APPENDED, never prepended: `scripts/serve/` holds `tracing.py`,
        # `probes.py` and friends whose names collide with modules `scripts/`
        # tests import, and putting it first silently resolved three unrelated
        # suites (fleet_rollout, instana_destination, trace_ship) against the
        # serving copy instead. `scripts/` stays ahead of it; nothing in
        # `scripts/` is named `walkin`, so the adopted package still resolves.
        sys.path.append(str(SERVE))
    suite = unittest.TestSuite()
    for name in ADOPTED:
        # A FRESH loader, not the one discovery handed us: `TestLoader` carries
        # the run's `_top_level_dir` (here `scripts/`), and a nested discover
        # under a different root trips its own "Path must be within the
        # project" assertion instead of returning tests.
        suite.addTest(unittest.TestLoader().discover(str(SERVE / name), pattern="test_*.py", top_level_dir=str(SERVE)))
    return suite
