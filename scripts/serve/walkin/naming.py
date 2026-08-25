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

# Ledger §5.1 / brief §9 decision 6. Production stations end at 151; the edge
# relay DNAT window ends at 54200, which is what caps the range at 200.
SLOT_MIN = 152
SLOT_MAX = 200
UDP_PORT_BASE = 54000

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
    """
    return f"02:00:00:00:57:{check_slot(slot):02x}"


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


def cell_peer_ip(slot: int) -> str:
    """The address the GATEWAY sees for this clone: 10.99.0.<slot-100>.

    Slots 152-200 map onto .52-.100, a range reserved in ledger §6 — clear of
    the gateway (.2), every baked station address, and the containment-proof
    addresses (.240/.241). The guest never sees this number: inside the cell it
    still holds the address its golden was captured with, and the cell's SNAT
    is what makes both facts true at once.
    """
    return f"10.99.0.{check_slot(slot) - 100}"


def clone_root(ident: str) -> Path:
    return WALKIN_ROOT / ident


def unit_name(ident: str) -> str:
    return f"walkin-clone@{ident}.service"
