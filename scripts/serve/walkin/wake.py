"""`guest_wake.WakeLease`, resolved from wherever the box put it.

A paused guest ACCEPTS everything and does none of it — `cont` acks, `loadvm`
fails with `Invalid argument`, and a screendump shows the unchanged screen. The
station daemon pauses its guest 60 s after the last visitor and re-asserts that
pause on a reconciler, so a broker-side resume or restore that does not hold a
lease is undone underneath it. Lane 7 met this as
`Could not load snapshot 'golden' on 'ide0-hd0'` on a perfectly healthy station,
and could not reproduce it until it stopped holding the lease.

Two places in this package touch a guest the daemon believes is paused: the
resume behind a claim, and the teardown behind a reset. Both are visitor-facing.
A stranger who leaves the machine alone for a minute and then clicks "give me a
fresh one" must not be told the reset failed.

**Why this file exists rather than a plain import.** `guest_wake.py` lives in
`scripts/lib/` and box-syncs to `/usr/local/lib/labctl/`, while this package
syncs to the serve tree — different destinations, so the import has to be
resolved rather than assumed. And if it cannot be resolved, the serving process
must not die: `lease()` degrades to the weaker retry the ledger names as the
fallback, loudly and once, because "reset sometimes fails" is a smaller outage
than "the walk-in plane does not import".
"""

from __future__ import annotations

import contextlib
import os
import sys
import time
from pathlib import Path

_SEARCH = [
    os.environ.get("GUEST_WAKE_DIR", ""),
    "/usr/local/lib/labctl",
    str(Path(__file__).resolve().parents[2] / "lib"),
]

_WARNED = False


def _load():
    for candidate in _SEARCH:
        if candidate and (Path(candidate) / "guest_wake.py").exists() and candidate not in sys.path:
            sys.path.append(candidate)
    try:
        import guest_wake  # noqa: PLC0415

        return guest_wake
    except ImportError:
        return None


_GUEST_WAKE = _load()


def _warn_once() -> None:
    global _WARNED
    if not _WARNED:
        _WARNED = True
        sys.stderr.write(
            "[walkin] guest_wake is not importable — falling back to retrying `cont`. "
            "A resume or reset may lose a race with the daemon's idle-pauser "
            f"(searched {[c for c in _SEARCH if c]})\n"
        )


def lease(station: str):
    """A wake lease for `station`, or a no-op context if the module is absent."""
    if _GUEST_WAKE is None:
        _warn_once()
        return contextlib.nullcontext()
    return _GUEST_WAKE.WakeLease(station)


def wake(execute, station: str, timeout: float = 8.0) -> None:
    """Resume and PROVE it resumed. Raises if the guest stayed stopped.

    The fallback path retries rather than hoping, because an unverified `cont`
    is how the caller learns nothing: the ack means the command was accepted,
    never that the vCPUs moved.
    """
    if _GUEST_WAKE is not None:
        _GUEST_WAKE.wake(execute, station, timeout=timeout)
        return
    _warn_once()
    deadline = time.monotonic() + timeout
    while True:
        status = execute("query-status")
        if isinstance(status, dict) and status.get("running"):
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"{station}: guest did not resume within {timeout:.0f}s of `cont` — it is idle-auto-paused, "
                "not wedged. Nothing sent to it was delivered."
            )
        execute("cont")
        time.sleep(0.2)


def assert_running(execute, station: str, what: str = "the resume") -> None:
    if _GUEST_WAKE is not None:
        _GUEST_WAKE.assert_running(execute, station, what)
        return
    status = execute("query-status")
    if not (isinstance(status, dict) and status.get("running")):
        raise RuntimeError(f"{station}: re-frozen while {what} was in flight; do not trust what happens next.")
