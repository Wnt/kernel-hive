"""Where the forwarder's configuration comes from.

SPLIT OUT OF `instana-forward.py` on 2026-09-01: the logs leg and the
telemetry-call filter landed in that file on the same day and together pushed
it past its 600-line budget. Reading configuration is a separable concern and
it comes away whole. Moved verbatim.
"""

from __future__ import annotations

import os
from pathlib import Path

#: Repo root, as seen from scripts/observability/.
ROOT = Path(__file__).resolve().parents[2]


def load_env() -> dict:
    """registry/local.env, then the real environment on top."""
    env = {}
    path = ROOT / "registry" / "local.env"
    try:
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip("\"'")
    except OSError:
        pass
    # INSTANA_* plus the two store paths this reads. The store paths matter
    # because they are how anyone tests this against a fixture instead of the
    # live databases — filtering them out made `Config` claim to honour an
    # override it never saw, which is worse than not offering one.
    passthrough = ("TRACES_DB", "ANALYTICS_DB", "LOGS_DB")
    env.update({k: v for k, v in os.environ.items() if k.startswith("INSTANA_") or k in passthrough})
    return env
