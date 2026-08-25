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

import re
import sys

from . import cell, claims, naming
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
    try:
        known |= _claimed_taps()
    except Exception as exc:
        # No registry means no way to tell mine from another broker's. Skip
        # the sweep this tick: a leaked tap can wait, a stolen one cannot.
        sys.stderr.write(f"[walkin] cannot read the claim registry ({exc}); skipping the tap sweep\n")
        return []
    reaped = []
    for tap in cell.live_taps():
        if tap in known:
            continue
        station = cell.TAP_RE.match(tap).group("station")
        if cell.tapnet_down(station, tap):
            reaped.append(tap)
        else:
            sys.stderr.write(f"[walkin] orphan tap {tap} would not go down; the next clone at that index will fail\n")
    return reaped


def _claimed_taps() -> set:
    """Tap names standing behind ANY walk-in claim in the registry, any session.

    Two brokers share one box (the serving unit, and every dev stack rule 3
    hands out), and interface names are global. A sweep that knows only its own
    members treats the other broker's taps as orphans and deletes them out
    from under running guests — measured 2026-08-26, nine taps inside one
    tick. The claim registry is the one box-wide record of ownership (rule 7),
    so a claimed identity's tap is KNOWN here whoever owns it. Raises when the
    registry cannot be read; the caller then skips the sweep for this tick —
    a leaked tap can wait, a stolen one cannot.
    """
    out = set()
    for row in claims.everyone(claims.SLOT_CLASS):
        identity = claims.purpose_identity(row.get("purpose", ""))
        found = re.match(r"^walkin-(?P<station>[a-z][a-z0-9]{1,15})-(?P<index>\d+)$", identity)
        if found:
            # Both shapes a station may declare: the default wi-<os>-<n> and
            # any per-station ifnamePattern are index-suffixed; guarding the
            # default covers the production plane, and a dev plane that
            # renames its taps is invisible to this sweep anyway.
            out.add(f"wi-{found.group('station')}-{found.group('index')}")
    return out


def _claimed_slots() -> set:
    """Slots standing behind ANY walk-in claim — same reasoning as taps."""
    out = set()
    for row in claims.everyone(claims.SLOT_CLASS):
        try:
            out.add(int(row.get("name", "")))
        except (TypeError, ValueError):
            continue
    return out


def reap_orphan_cells(known_slots: set) -> list:
    """Walk-in L2 cells (`wibr<slot>`, wi-clonecell) that no clone stands behind.

    Same shape and same stakes as an orphan tap: a cell outlives its clone when
    a build fails between `cell up` and the crumb landing, and because a cell is
    keyed by SLOT, a leaked one makes the next claim of that slot unbuildable —
    `ip link add wibr<slot>` fails and the watchdog re-fails every tick.
    """
    known_slots = set(known_slots)
    try:
        for entry in naming.WALKIN_ROOT.iterdir():
            if entry.is_dir():
                slot = clone_mod.read_manifest(entry).get("slot")
                if isinstance(slot, int):
                    known_slots.add(slot)
    except OSError:
        pass
    try:
        known_slots |= _claimed_slots()
    except Exception as exc:
        sys.stderr.write(f"[walkin] cannot read the claim registry ({exc}); skipping the cell sweep\n")
        return []
    reaped = []
    for slot in cell.live_cells():
        if slot in known_slots:
            continue
        if cell.cell_down(slot):
            reaped.append(slot)
        else:
            sys.stderr.write(
                f"[walkin] orphan cell wibr{slot} would not go down; the next claim of slot {slot} will fail\n"
            )
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
