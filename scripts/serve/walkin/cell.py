"""Host-side plumbing shared by clones and their reapers: taps and cells.

The tap is a station-owned thing (each station's `wi-tapnet.sh` builds and
guards its own); the CELL is a plane-owned thing (`wi-clonecell`, ledger §6) —
one bridge + NAT namespace per clone, which is what lets identical restored
machines share the walk-in plane at all. Both leak the same way: a build that
fails between "up" and the crumb landing leaves a kernel object nothing
records, and the name it carries (pool index for a tap, SLOT for a cell)
blocks the next clone that needs it. So both are enumerable from the kernel
and destroyable by name, which is everything a reaper needs.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

CLONECELL = os.environ.get("WALKIN_CLONECELL", "/usr/local/sbin/wi-clonecell")
#: Where the kernel publishes interfaces. Named so tests can point at a temp
#: dir — the alternative is a health check nobody can prove answers TRUE.
NET_SYSFS = Path("/sys/class/net")
STATIONS_ROOT = Path(os.environ.get("WALKIN_STATIONS_ROOT", "/data/vms/streamhost/stations"))


def _run(argv: list, env: dict | None = None, check: bool = False) -> subprocess.CompletedProcess:
    del check  # every caller here tolerates failure; enumerate-and-destroy must keep going
    return subprocess.run(argv, capture_output=True, text=True, env=env or os.environ.copy(), check=False)


TAP_RE = re.compile(r"^wi-(?P<station>[a-z][a-z0-9]{1,15})-(?P<index>\d+)$")


def tapnet_down(station: str, tap: str, bridge: str = "") -> bool:
    """Take one walk-in tap down through the station's own script.

    The script, not `ip link del`, because the tap is only half of what a `up`
    created: the other half is the fail-closed guard chain scoped to that
    interface, and deleting the link alone leaves the chain behind. Falls back to
    removing the link only if the script is not on the box, which is better than
    leaving a tap that will collide with the next clone of the same index.
    """
    script = STATIONS_ROOT / station / "wi-tapnet.sh"
    env = {**os.environ, "WI_TAP_IF": tap, "WI_TAP_BRIDGE": bridge or "vmbr-wi"}
    if script.exists():
        _run(["bash", str(script), "down"], env=env, check=False)
    if NET_SYSFS.joinpath(tap).exists():
        _run(["ip", "link", "del", tap], check=False)
    return not NET_SYSFS.joinpath(tap).exists()


CELL_RE = re.compile(r"^wibr(?P<slot>\d{3})$")


def live_cells() -> list:
    """Every walk-in cell bridge currently on the box, by slot."""
    out = []
    try:
        for entry in NET_SYSFS.iterdir():
            found = CELL_RE.match(entry.name)
            if found:
                out.append(int(found.group("slot")))
    except OSError:
        pass
    return sorted(out)


def network_present(plan) -> bool:
    """Whether this clone's tap AND its cell bridge are still in the kernel.

    `Clone.alive()` asks only whether QEMU is running, and a guest whose tap was
    deleted under it goes on running perfectly while able to reach nothing at
    all. On 2026-09-11 the orphan sweeps' own stale-snapshot race did exactly
    that to SIX of twenty-four pool members, and every one stayed a listed,
    claimable member — handed to visitors with no network interface — because
    the pid was fine and nothing else was ever asked. A member that has lost
    either half of its plumbing is not a pool member; the watchdog retires it
    and the pool builds a replacement.
    """
    return not missing_half(plan)


def missing_half(plan) -> str:
    """Which half of this clone's plumbing is gone — tap or cell — or ""."""
    if not NET_SYSFS.joinpath(plan.tap).exists():
        return plan.tap
    return "" if NET_SYSFS.joinpath(f"wibr{plan.slot}").exists() else f"wibr{plan.slot}"


def cell_down(slot: int) -> bool:
    """Tear one cell down through the plane's own helper."""
    _run([CLONECELL, "down", str(int(slot))], check=False)
    return not NET_SYSFS.joinpath(f"wibr{int(slot)}").exists()


def live_taps() -> list:
    """Every walk-in tap currently on the box, by name."""
    try:
        return sorted(p.name for p in NET_SYSFS.iterdir() if TAP_RE.match(p.name))
    except OSError:
        return []
