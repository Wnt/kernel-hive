"""Names and numbers for a walk-in clone — all of them frozen in the contract
ledger (`docs/lab/walkin/CONTRACT-LEDGER.md` §5.1), none of them ours to choose.

A clone is not a registry station: it is an ephemeral daemon identity spawned
from a station's seed + checkpoint, and every shared number it needs (slot, UDP
port, tap, VMID) is derived from ONE claimed slot so that a single atomic claim
(`kh-claim`, rule 7) covers the whole set. Deriving them instead of claiming
each separately is what makes "it is mine" one fact rather than four.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

# Ledger §5.1 / brief §9 decision 6, re-cut 2026-09-10 for the poolSize 3->8
# raise (docs/lab/walkin/CONTRACT-LEDGER.md §5.4). Until this date the walk-in
# pool shared the low end of the production fleet's own numbering (152-170,
# re-cut down from an original 152-200 when the fleet ran short of slots --
# registry/stations/aix432.json's scaffold comment records that cut) and had
# no room left to grow into: production filled 171-193 solid in between, and
# 194-199 was the last free sliver below the edge's old relay ceiling.
#
# The edge relay DNAT window itself was widened instead (Wnt/forwarder
# deploy/site.env UDP_RELAY_PORT_RANGE, commit 530c9f3 -- a separate repo,
# CI-deployed to the edge's own nftables; verified against the live edge with
# the same probe method as docs/lab/walkin/PREFLIGHT.md, not read off a doc).
# The pool now gets its OWN window, wholly separate from production
# territory, so the two can never collide again and neither has to be re-cut
# to grow the other. 152-170 is vacated back to the production fleet, which
# badly needed it (scripts/stations_registry/generate.py:slot_refusal no
# longer reserves it); production stations must now stay below SLOT_MIN
# (enforced there too, so a `--slot auto` cannot wander into this window).
SLOT_MIN = 256
SLOT_MAX = 511
UDP_PORT_BASE = 54000
# 200 remains the WebRTC bridge's PERMANENT ICE port (ports.webrtcBridgeUdp)
# regardless of the window move -- it sits well below SLOT_MIN and is refused
# independently, by exact port match, in slot_refusal.

# Clones never run in the production VMID range; clone-guard refuses < 900.
VMID_BASE = 9000

# Overridable so a development stack can put its clones inside its own sandbox
# (rule 4: never experiment beside the live fleet). Production leaves it alone;
# clone-guard is pointed at whatever this says, so the guard and the broker can
# never disagree about which tree is the clone tree.
WALKIN_ROOT = Path(os.environ.get("WALKIN_ROOT", "/data/vms/walkin"))
SLICE = "walkin.slice"

_STATION_RE = re.compile(r"^[a-z][a-z0-9]{1,15}$")
IFNAME_MAX = 15  # kernel limit on an interface name


class NameError_(ValueError):
    """A name or number that would not survive contact with the kernel."""


def check_station(station: str) -> str:
    if not _STATION_RE.match(station or ""):
        raise NameError_(f"not a station id: {station!r}")
    return station


def check_slot(slot: int) -> int:
    if not isinstance(slot, int) or isinstance(slot, bool):
        raise NameError_(f"slot must be an int, got {slot!r}")
    if not SLOT_MIN <= slot <= SLOT_MAX:
        raise NameError_(f"slot {slot} outside the walk-in range {SLOT_MIN}-{SLOT_MAX}")
    return slot


def identity(station: str, index: int) -> str:
    """`walkin-<os>-<n>` — the clone's one name, everywhere."""
    check_station(station)
    if not isinstance(index, int) or index < 1:
        raise NameError_(f"pool index must be >= 1, got {index!r}")
    return f"walkin-{station}-{index}"


def tap_name(station: str, index: int, pattern: str = "") -> str:
    """`wi-<os>-<n>`, or the station's own `ifnamePattern` with %d filled in.

    Checked against the 15-character kernel limit HERE rather than at `ip link`
    time, because a too-long name fails at tap creation — inside the launch,
    after the claim, with a half-built clone to unwind.
    """
    check_station(station)
    name = (pattern % index) if pattern else f"wi-{station}-{index}"
    if len(name) > IFNAME_MAX:
        raise NameError_(f"tap name {name!r} is {len(name)} chars, kernel limit is {IFNAME_MAX}")
    return name


def udp_port(slot: int) -> int:
    return UDP_PORT_BASE + check_slot(slot)


def vmid(slot: int) -> int:
    return VMID_BASE + check_slot(slot)


def clone_mac(slot: int) -> str:
    """The per-clone MAC the ledger reserves — and DOES NOT SET.

    Kept because the scheme is documented and a future per-plane golden will
    want it. It is not applied to any `mac=`: `loadvm` restores the NIC address
    from saved device state, so a clone is whatever its golden was baked as
    (ledger §5.3). Anything that starts calling this to build a command line is
    about to create a machine whose command line disagrees with its own vmstate.

    Encodes `slot - SLOT_MIN`, not the raw slot, in the last octet: SLOT_MAX -
    SLOT_MIN + 1 is exactly 256 by construction, so the offset always fits one
    byte with no overflow across the whole window. A raw slot >= 256 (every
    slot since the 2026-09-10 window move, naming.py's header comment) would
    have formatted as 3+ hex digits (`{256:02x}` is `"100"`) -- not a MAC
    octet, and a silent one: nothing calls this today (see above), so nothing
    would have caught it before "a future per-plane golden" did.
    """
    return f"02:00:00:00:57:{check_slot(slot) - SLOT_MIN:02x}"


def cell_bridge(slot: int) -> str:
    """`wibr<slot>` — the clone's own L2 domain (ledger §6).

    Identical restored machines can never share a bridge: `loadvm` gives every
    clone of one station the same MAC, and one FDB entry cannot point at three
    ports. So each clone's tap is enslaved to its own bridge, and wi-clonecell's
    NAT namespace joins that cell to `vmbr-wi` as a unique peer.
    """
    return f"wibr{check_slot(slot)}"


def cell_netns(slot: int) -> str:
    """`wicell<slot>` — the cell's NAT namespace on labhost."""
    return f"wicell{check_slot(slot)}"


#: `cell_peer_ip`'s addresses stay inside the reserved 10.99.0.52-.100 block
#: (ledger §6) regardless of where SLOT_MIN sits, which bounds the pool to
#: this many CONCURRENTLY HELD slots -- not the width of SLOT_MIN..SLOT_MAX.
PEER_IP_CEILING = 100 - 52 + 1  # 49


def cell_peer_ip(slot: int) -> str:
    """The address the GATEWAY sees for this clone: 10.99.0.<52 + slot - SLOT_MIN>.

    Slots SLOT_MIN..SLOT_MIN+48 map onto .52-.100, a range reserved in ledger
    §6 — clear of the gateway (.2), every baked station address, and the
    containment-proof addresses (.240/.241). The guest never sees this number:
    inside the cell it still holds the address its golden was captured with,
    and the cell's SNAT is what makes both facts true at once.

    This is the pool's REAL ceiling as of the 2026-09-10 window move: SLOT_MIN
    and SLOT_MAX span 256 slots, but only the first 49 have a safe peer
    address, so a 50th CONCURRENTLY CLAIMED slot refuses here rather than
    silently wrapping the octet or colliding with a baked address above .100.
    scripts/retronet/walkin-net/wi-clonecell.sh mirrors this exact formula
    and this exact ceiling (its own WALKIN_PEER_BASE) — it is what actually
    programs the SNAT rule, so the two must never disagree.
    """
    offset = 52 + (check_slot(slot) - SLOT_MIN)
    if offset > 100:
        raise NameError_(
            f"slot {slot} would need peer 10.99.0.{offset}, past the reserved "
            "10.99.0.52-.100 block (ledger §6) -- the walk-in pool's peer-IP "
            f"ceiling is {PEER_IP_CEILING} concurrently held slots, not the width "
            "of SLOT_MIN..SLOT_MAX"
        )
    return f"10.99.0.{offset}"


def clone_root(ident: str) -> Path:
    return WALKIN_ROOT / ident


def unit_name(ident: str) -> str:
    return f"walkin-clone@{ident}.service"
