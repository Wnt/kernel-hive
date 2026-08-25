"""Giving back what no clone stands behind.

Three kinds of leftover, each of which has cost the live plane something:

* **Clone roots** whose broker died or was restarted. `/run` claims and running
  QEMUs both survive a service restart, and neither is ours afterwards — a clone
  is never handed to a second visitor, and that includes the visitor who was on
  it before the restart.
* **Taps.** A build that failed after `tapnet up` used to leave its interface on
  the bridge for good; fifteen accumulated in one afternoon. The name carries the
  clone's POOL INDEX, so a leaked tap does not merely litter — it makes the next
  clone at that index impossible to create, and the watchdog then rebuilds and
  re-fails on every tick.
* **Claims.** Under the exclusive-take rule (see `claims.py`) an inherited claim
  with no clone behind it is a refusal, and kh-claim's own staleness rule would
  clear it after twelve hours — an outage with a timer on it, not a recovery.

Each reaper is told what the caller knows to be live and scans the WORLD for
everything else — the kernel's interface list, the clone tree, the claim
registry. That direction matters: the leaked things are, by definition, the ones
no record of ours mentions.
"""

from __future__ import annotations

import sys

from . import claims, naming
from . import clone as clone_mod


def reap_orphan_dirs(known: set) -> list:
    """Clone roots on disk that this broker does not own — kill and discard.

    These are what a crashed or restarted serving process leaves behind. The
    pool cannot refill past its ceiling while their slots are still claimed,
    so an unreaped orphan is a pool that quietly shrinks.
    """
    root = naming.WALKIN_ROOT
    try:
        entries = sorted(root.iterdir())
    except OSError as exc:
        # Not there yet (nothing has been built), or not ours to read. Either
        # way the watchdog must keep running: a reaper that dies on a
        # permission error stops reaping the clones it CAN see.
        if root.exists():
            sys.stderr.write(f"[walkin] cannot scan {root} for orphans: {exc}\n")
        return []
    found = []
    for entry in entries:
        if not entry.is_dir() or entry.name in known or not entry.name.startswith("walkin-"):
            continue
        clone_mod.reap_orphan(entry)
        found.append(entry.name)
    return found


def reap_orphan_taps(known: set) -> list:
    """Walk-in taps on the box that no clone stands behind.

    A tap outlives its clone if the build failed after bringing it up, and
    an orphaned tap is not merely untidy: its name carries the clone's pool
    index (`wi-os2warp-2`), so the next clone allotted that index cannot be
    created — `ip link add` fails, the build fails, the watchdog tries the
    next index and fails again. Fifteen of these accumulated on the live
    plane in one afternoon and would have failed the next fifteen os2warp
    builds in a row.

    Scanned from `/sys/class/net` rather than from any record we keep,
    because the leaked ones are by definition the ones nothing recorded.
    """
    known = set(known)
    try:
        for entry in naming.WALKIN_ROOT.iterdir():
            if entry.is_dir():
                known.add(clone_mod.read_manifest(entry).get("tap", ""))
    except OSError:
        pass
    reaped = []
    for tap in clone_mod.live_taps():
        if tap in known:
            continue
        station = clone_mod.TAP_RE.match(tap).group("station")
        if clone_mod.tapnet_down(station, tap):
            reaped.append(tap)
        else:
            sys.stderr.write(f"[walkin] orphan tap {tap} would not go down; the next clone at that index will fail\n")
    return reaped


def release_stray_claims(known: set) -> list:
    """Give back slot and port claims that no clone stands behind.

    The claim registry lives in `/run`, which survives a service restart —
    so a restarted broker inherits its own previous incarnation's claims,
    under its own session name, with no clone attached to any of them. Under
    the exclusive-take rule those claims are now REFUSALS: nothing can be
    built on them, and the pool wedges at "no free slot" against a range that
    is almost entirely idle. kh-claim's own staleness rule would clear them
    eventually — after twelve hours, because they carry no pid — which is not
    a recovery, it is an outage with a timer on it.

    A claim is a stray when its purpose names a clone identity that is
    neither a live pool member nor a directory on disk. Both halves matter:
    `_members` alone would reap a clone another thread is mid-build, and the
    directory alone would miss one whose crumb has not landed yet.
    """
    try:
        on_disk = {p.name for p in naming.WALKIN_ROOT.iterdir() if p.is_dir()}
    except OSError:
        on_disk = set()
    released = []
    for row in claims.mine():
        klass, name = row.get("class", ""), row.get("name", "")
        if klass not in (claims.SLOT_CLASS, claims.PORT_CLASS):
            continue
        purpose = row.get("purpose", "")
        identity = claims.purpose_identity(purpose)
        if not identity.startswith("walkin-"):
            continue  # not ours to judge: some other tool's port claim
        root = claims.purpose_root(purpose)
        if root and root != str(naming.WALKIN_ROOT):
            # Another broker's clone tree under the same session name — a dev
            # sandbox beside production, or the reverse. Its claims are not
            # strays just because we have never heard of the identity.
            continue
        if identity in known or identity in on_disk:
            continue
        claims.release(klass, name)
        released.append(f"{klass}/{name}")
    return released
