#!/usr/bin/env python3
"""The honest door onto a guest that streamhost may have idle-auto-paused.

WHY THIS EXISTS. A QEMU guest whose vCPUs are stopped still ACCEPTS input.
``sendkey`` returns ``{"return": {}}``, ``input-send-event`` returns
``{"return": {}}``, and the guest reacts to none of it. streamhost pauses every
station 60 s after its last visitor (``SH_IDLE_PAUSE_SECS``), so any tool that
drives a station without a browser attached — ``labctl``, ``qmp-type.py``, an
install harness — was typing into a void and then screendumping the unchanged
screen as its proof. That reads exactly like a wedged guest, and it sent
several 2026-08-23 investigations after the emulator instead of the pause. In a
lab whose first rule is "the framebuffer is the only proof", an interface that
acks what it discards manufactures false evidence.

THE CONTRACT this module enforces, the same one MAME's ctlsock already keeps:
**an ack means the event was delivered to a RUNNING guest.** Two halves, and
you need both:

  * ``wake()`` — resume, then VERIFY with ``query-status`` that the guest is
    actually running, and raise :class:`GuestPaused` if it is not. Issuing
    ``cont`` and hoping is what the old best-effort ``ensure_running`` did; a
    ``cont`` can fail (another QMP client holds the socket) and the caller
    learned nothing.
  * ``WakeLease`` — hold the guest awake for as long as you are driving it.
    streamhost's reconciler re-asserts a believed pause every 60 s, so a
    ``cont`` alone is undone in the MIDDLE of a long sequence and the remaining
    keystrokes vanish with an OK on the wire. This is the race the folklore
    ("send ``cont`` and your input back-to-back on ONE QMP connection") was
    dodging rather than fixing. The lease is one file whose mtime the daemon
    reads; a driver that dies leaves a lease that expires on its own, so idle
    auto-pause — worth ~10% of a core per station — is never weakened.

USE IT LIKE THIS::

    from guest_wake import GuestPaused, WakeLease, wake, assert_running

    with WakeLease(station):          # daemon will not re-freeze under us
        wake(qmp.execute, station)    # resume + verify, or raise GuestPaused
        ...inject input...
        assert_running(qmp.execute)   # the guest was awake the WHOLE time
        ...screendump...

``assert_running`` at the END is what makes the framebuffer admissible: without
it a screenshot cannot distinguish "the guest ignored the input" from "the guest
was re-frozen halfway through and never saw it".
"""

from __future__ import annotations

import os
import threading
import time

# Must match Config::wake_lease in streamhost/streamhost/src/config/mod.rs.
# Derived from the station NAME so a driver can compute it from the one
# identifier it always has, without reading the station directory.
LEASE_DIR = os.environ.get("SH_WAKE_LEASE_DIR", "/run/streamhost/wake")

# Must be comfortably under LEASE_TTL in streamhost/streamhost/src/idle.rs (90 s).
REFRESH_SECS = 20.0


class GuestPaused(RuntimeError):
    """The guest is frozen and would not wake — so nothing was delivered.

    Raised INSTEAD of injecting. That is the whole point: the caller now knows
    why the guest did not react, rather than inferring a wedge from a
    screenshot that never changed.
    """


def lease_path(station: str) -> str:
    """Where this station's wake lease lives. ``SH_WAKE_LEASE`` overrides."""
    override = os.environ.get("SH_WAKE_LEASE")
    if override:
        return override
    return os.path.join(LEASE_DIR, f"{station}.lease")


def touch_lease(station: str) -> bool:
    """Claim/refresh the wake lease. False if the path is unusable.

    Best-effort BY DESIGN, and the only best-effort thing here: a station whose
    /run is not writable simply behaves as it did before this module existed —
    ``wake()`` still verifies, so nothing silently vanishes; the driver is just
    exposed to the 60 s re-assert again. Failing the whole call over a lease
    would break every non-root caller for no safety gain.
    """
    path = lease_path(station)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a"):
            os.utime(path, None)
        return True
    except OSError:
        return False


class WakeLease:
    """Hold a station awake for the duration of a ``with`` block.

    Refreshes in a daemon thread every ``REFRESH_SECS`` so a sequence of any
    length is covered, and stops on exit — the lease then expires on its own and
    the station goes back to pausing normally.
    """

    def __init__(self, station: str, refresh: float = REFRESH_SECS) -> None:
        self.station = station
        self.refresh = refresh
        self.held = False
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def __enter__(self) -> WakeLease:
        self.held = touch_lease(self.station)
        if self.held:
            self._thread = threading.Thread(target=self._loop, daemon=True)
            self._thread.start()
        return self

    def _loop(self) -> None:
        while not self._stop.wait(self.refresh):
            touch_lease(self.station)

    def __exit__(self, *_exc: object) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=1)


def is_running(execute) -> bool:
    """Does QEMU say the vCPUs are running right now?

    ``execute`` is any callable taking a QMP command name and returning its
    ``return`` value — ``labctl.d.common.QmpConn.execute`` and
    ``scripts/lib/labqmp.QMPClient.execute`` both qualify.
    """
    status = execute("query-status")
    return bool(isinstance(status, dict) and status.get("running"))


def wake(execute, station: str | None = None, timeout: float = 8.0) -> None:
    """Resume the guest and PROVE it resumed, or raise :class:`GuestPaused`.

    ``cont`` is idempotent, so calling this on a running guest costs one
    ``query-status`` and returns. On a paused one it conts and then polls until
    QEMU agrees the vCPUs are running — a ``cont`` that lost the QMP socket to
    another client fails HERE, loudly, instead of two hundred discarded
    keystrokes later.
    """
    if station:
        touch_lease(station)
    if is_running(execute):
        return
    execute("cont")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if is_running(execute):
            return
        time.sleep(0.05)
    who = f" {station}" if station else ""
    raise GuestPaused(
        f"guest{who} is idle-auto-paused (streamhost SH_IDLE_PAUSE_SECS) and did not "
        f"resume within {timeout:.0f}s of `cont` — NOTHING was delivered. The guest is "
        "not wedged; its vCPUs are stopped. Check that no other QMP client holds the "
        "station's qmp.sock, and see docs/lab/INPUT-DEBUGGING.md."
    )


def assert_running(execute, station: str | None = None, what: str = "the input") -> None:
    """Fail if the guest is not running NOW — call it AFTER injecting.

    A guest that froze part-way through a sequence swallowed the rest of it, and
    the screendump that follows would be evidence for a claim nobody can make.
    """
    if is_running(execute):
        return
    who = f" {station}" if station else ""
    raise GuestPaused(
        f"guest{who} was re-frozen while {what} was being sent, so an unknown part of "
        "it was DISCARDED — do not trust a screendump taken now. Hold a "
        "guest_wake.WakeLease (or guest_wake.hold_lease) for the whole sequence."
    )


_HELD: dict[str, WakeLease] = {}


def hold_lease(station: str) -> WakeLease:
    """Hold this station's wake lease for the lifetime of the CURRENT PROCESS.

    The shape most drivers actually want. A CLI like ``labctl`` is one verb per
    invocation with early returns and ``sys.exit`` all through it, so threading a
    ``with`` block around every path is churn for no benefit — while the thing
    that matters, "do not re-freeze the guest until this command is finished",
    is exactly process lifetime. The refresher is a daemon thread, so it dies
    with the process and the lease then expires on its own.

    Idempotent per station: a second call returns the lease already held.
    """
    lease = _HELD.get(station)
    if lease is None:
        lease = WakeLease(station)
        lease.__enter__()
        _HELD[station] = lease
    return lease
