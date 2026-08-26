"""The retronet ledger check: registry `retronet` blocks vs the ICQ roster."""

from __future__ import annotations

import re
from typing import Any

from .constants import ICQ_ROSTER, REPO
from .loading import icq_roster
from .validate_schema import fail

RETRONET_PLANES = ("web", "icq")
RETRONET_KEYS = ("planes", "address", "addressing", "link", "guard", "joined", "doc")
RETRONET_GATEWAY = "10.99.0.2"
BOX_SYNC_PAIRS = REPO / "scripts/lib/box-sync-pairs.sh"
# A FAMILY since box-sync-pairs.sh hit its hard cap and the per-station
# network-link rows moved to box-sync-pairs-retronet.sh — read them all.
BOX_SYNC_PAIRS_FAMILY = sorted((REPO / "scripts/lib").glob("box-sync-pairs*.sh"))


def _tapnet_pairs() -> tuple[set[str], str]:
    """Station ids that box-sync-pairs.sh registers an `rn-tapnet` pair for."""
    rel = str(BOX_SYNC_PAIRS.relative_to(REPO))
    if not BOX_SYNC_PAIRS.exists():
        return set(), rel
    text = "\n".join(f.read_text(encoding="utf-8") for f in BOX_SYNC_PAIRS_FAMILY)
    return set(re.findall(r"^\s*box_sync_add_pair\s+([a-z0-9_]+)-rn-tapnet\b", text, re.M)), rel


def validate_retronet(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """The retronet ledger, checked in BOTH directions.

    Membership of the offline bridge lives in two hand-written places on
    purpose — the station's `retronet` block (bridge facts) and
    scripts/retronet/icq/roster.json (the ICQ persona) — so each fact has one
    home. That only stays true if drift between them is a gate failure: an
    address reused or landing on the gateway, an onboarded roster row whose
    station never declared the icq plane, a station claiming the plane with no
    persona, or a doc path that has been moved away underneath the block.

    It also guards the one deploy-time trap this bridge keeps re-inflicting:
    a station's `rn-tapnet.sh` that no box-sync pair carries to the box.
    """
    roster = icq_roster()
    roster_rel = ICQ_ROSTER.relative_to(REPO)
    tapnet_pairs, pairs_rel = _tapnet_pairs()
    addresses: dict[str, str] = {}
    icq_planes: set[str] = set()
    for row in rows:
        block = row.get("retronet")
        if not block:
            continue
        os_id = row["id"]
        unknown = sorted(set(block) - set(RETRONET_KEYS))
        if unknown:
            fail(errors, row, f"retronet has unknown key(s) {unknown}; allowed: {list(RETRONET_KEYS)}")
        planes = block.get("planes") or []
        if not planes:
            fail(errors, row, "retronet.planes must name at least one plane")
        if len(set(planes)) != len(planes):
            fail(errors, row, f"retronet.planes has a duplicate: {planes}")
        for plane in planes:
            if plane not in RETRONET_PLANES:
                fail(errors, row, f"retronet.planes {plane!r} is not one of {list(RETRONET_PLANES)}")
        address = block.get("address")
        if address is not None:
            if not re.fullmatch(r"10\.99\.0\.(\d{1,3})", address) or not 3 <= int(address.rsplit(".", 1)[1]) <= 254:
                fail(
                    errors,
                    row,
                    f"retronet.address {address!r} is not an assignable 10.99.0.0/24 host address "
                    f"(.1 is the labhost side of the bridge and {RETRONET_GATEWAY} the gateway CT)",
                )
            elif address in addresses:
                fail(errors, row, f"retronet.address {address} is already taken by {addresses[address]}")
            else:
                addresses[address] = os_id
        doc = block.get("doc")
        if doc and not (REPO / doc).exists():
            fail(errors, row, f"retronet.doc does not exist: {doc}")
        if (REPO / f"streamhost/stations/{os_id}/rn-tapnet.sh").exists() and os_id not in tapnet_pairs:
            fail(
                errors,
                row,
                f"streamhost/stations/{os_id}/rn-tapnet.sh has no `box_sync_add_pair {os_id}-rn-tapnet` "
                f"row in {pairs_rel}. The generic launcher sweep carries qemu-streamhost.sh but NOT the "
                "helper it calls, so the helper reaches the box checkout and never the station dir, and "
                'the launcher dies on start at `bash "$B/rn-tapnet.sh" up`. beos, w2kalpha and rhapsody '
                "each lost a boot cycle to this; register the pair instead of becoming the fourth.",
            )
        if "icq" in planes:
            icq_planes.add(os_id)
            if os_id not in roster:
                fail(errors, row, f"retronet declares the icq plane but {roster_rel} has no row for {os_id}")
    by_id = {row["id"]: row for row in rows}
    for station, persona in sorted(roster.items()):
        if not persona.get("onboarded"):
            continue
        if station not in by_id:
            errors.append(f"{roster_rel}: onboarded row {station!r} is not a station in the registry")
        elif station not in icq_planes:
            errors.append(
                f"{roster_rel}: {station} is onboarded (UIN {persona['uin']}) but "
                f"registry/stations/{station}.json does not declare the retronet icq plane"
            )
