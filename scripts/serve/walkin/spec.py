"""`registry/walkin/<station>.json` — adding an OS to the walk-in pool is DATA.

The broker reads this file; the per-station enablement lanes write it. Schema is
frozen in the contract ledger §5.2, and **an unknown key is an error, not a
silent ignore**: a typo'd `poolsize` that quietly meant "default 0" would look
exactly like a station nobody enabled, and the operator would go hunting the
broker for a fault that is one character in a JSON file.

The important half of this module is `_check_overrides`. The ledger allows an
override to change **paths, ports, tap names and netdev options only** — never
to add, remove or retype a device — because `loadvm` matches the device set the
golden was captured against and the binary is bound to that same combination
(`docs/lab/OPERATING-RULES.md` rule 6). This file rejects the *shape* of a
forbidden override; `deviceset.py` rejects its *effect* on the command line.
Both, because one is a spelling check and the other is the actual guarantee.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

REGISTRY_DIR = Path("registry/walkin")

_TOP_KEYS = {"station", "enabled", "poolSize", "seed", "overlay", "launcher", "overrides", "sandbox"}
_SEED_KEYS = {"disk", "readOnly"}
_OVERLAY_KEYS = {"format", "discardOnKill"}
_OVERRIDE_KEYS = {"netdev", "tapnet", "binary"}
_NETDEV_KEYS = {"type", "bridge", "ifnamePattern"}

# A netdev backend is a HOST-side attachment, not a guest device: the guest keeps
# whatever `-device` the golden was baked with either way. These are the backends
# the broker knows how to build a command line for.
NETDEV_TYPES = ("tap", "user", "none")

POOL_SIZE_MAX = 8


class SpecError(ValueError):
    """A walk-in station file that the broker refuses to act on."""


@dataclass(frozen=True)
class NetdevOverride:
    type: str = "tap"
    bridge: str = ""
    ifname_pattern: str = ""


@dataclass(frozen=True)
class StationSpec:
    station: str
    enabled: bool
    pool_size: int
    seed_disk: str
    seed_read_only: bool
    overlay_format: str
    overlay_discard_on_kill: bool
    launcher: str
    sandbox: bool
    netdev: NetdevOverride = field(default_factory=NetdevOverride)
    tapnet: str = ""
    # An absolute path pinning the emulator the golden was captured against —
    # rhapsody's i8259 fork, win311's patched SeaBIOS host. Rule 6 binds the
    # checkpoint to the binary, so this is not a preference: a clone that falls
    # back to stock pve-qemu is a clone whose guest loses every IDE interrupt.
    binary: str = ""
    source: str = "<memory>"


def _need(obj: dict, key: str, kind, where: str):
    if key not in obj:
        raise SpecError(f"{where}: missing required key {key!r}")
    val = obj[key]
    if not isinstance(val, kind) or isinstance(val, bool) is not (kind is bool):
        raise SpecError(f"{where}: {key!r} must be {getattr(kind, '__name__', kind)}, got {val!r}")
    return val


def _reject_unknown(obj: dict, allowed: set, where: str) -> None:
    extra = sorted(set(obj) - allowed)
    if extra:
        raise SpecError(f"{where}: unknown key(s) {extra} — the schema is contract-ledger §5.2, not a suggestion")


def _check_overrides(over: dict, where: str) -> tuple:
    _reject_unknown(over, _OVERRIDE_KEYS, f"{where}.overrides")
    net = over.get("netdev", {})
    if not isinstance(net, dict):
        raise SpecError(f"{where}.overrides.netdev must be an object")
    _reject_unknown(net, _NETDEV_KEYS, f"{where}.overrides.netdev")
    ntype = net.get("type", "tap")
    if ntype not in NETDEV_TYPES:
        raise SpecError(f"{where}.overrides.netdev.type {ntype!r} is not one of {NETDEV_TYPES}")
    pattern = str(net.get("ifnamePattern", ""))
    if pattern and "%d" not in pattern:
        raise SpecError(f"{where}.overrides.netdev.ifnamePattern {pattern!r} must carry a %d for the pool index")
    tapnet = over.get("tapnet", "")
    if not isinstance(tapnet, str):
        raise SpecError(f"{where}.overrides.tapnet must be a path string")
    binary = over.get("binary", "")
    if not isinstance(binary, str):
        raise SpecError(f"{where}.overrides.binary must be an absolute path to an emulator")
    if binary and not binary.startswith("/"):
        raise SpecError(f"{where}.overrides.binary {binary!r} must be absolute — a PATH lookup is not a pin")
    if ntype == "tap" and not tapnet:
        raise SpecError(f"{where}: a tap netdev needs an overrides.tapnet script to own the tap and its guard chain")
    return NetdevOverride(type=ntype, bridge=str(net.get("bridge", "")), ifname_pattern=pattern), tapnet, binary


def parse_spec(doc: dict, where: str = "<memory>") -> StationSpec:
    if not isinstance(doc, dict):
        raise SpecError(f"{where}: top level must be an object")
    _reject_unknown(doc, _TOP_KEYS, where)
    station = _need(doc, "station", str, where)
    pool_size = _need(doc, "poolSize", int, where)
    if not 0 <= pool_size <= POOL_SIZE_MAX:
        raise SpecError(f"{where}: poolSize {pool_size} outside 0..{POOL_SIZE_MAX}")
    seed = _need(doc, "seed", dict, where)
    _reject_unknown(seed, _SEED_KEYS, f"{where}.seed")
    read_only = bool(seed.get("readOnly", True))
    if not read_only:
        raise SpecError(f"{where}.seed.readOnly cannot be false — a walk-in never writes the golden disk")
    overlay = _need(doc, "overlay", dict, where)
    _reject_unknown(overlay, _OVERLAY_KEYS, f"{where}.overlay")
    netdev, tapnet, binary = _check_overrides(_need(doc, "overrides", dict, where), where)
    return StationSpec(
        station=station,
        enabled=bool(doc.get("enabled", False)),
        pool_size=pool_size,
        seed_disk=_need(seed, "disk", str, f"{where}.seed"),
        seed_read_only=read_only,
        overlay_format=str(overlay.get("format", "qcow2")),
        overlay_discard_on_kill=bool(overlay.get("discardOnKill", True)),
        launcher=_need(doc, "launcher", str, where),
        sandbox=bool(doc.get("sandbox", True)),
        netdev=netdev,
        tapnet=tapnet,
        binary=binary,
        source=where,
    )


def load_spec(path: Path) -> StationSpec:
    try:
        doc = json.loads(Path(path).read_text())
    except FileNotFoundError as exc:
        raise SpecError(f"{path}: no walk-in station file — the station is not enabled for walk-ins") from exc
    except json.JSONDecodeError as exc:
        raise SpecError(f"{path}: not valid JSON — {exc}") from exc
    return parse_spec(doc, str(path))


def load_all(directory: Path) -> dict[str, StationSpec]:
    """Every walk-in station file in `directory`, keyed by station id.

    A broken file is loud: it raises rather than dropping one OS out of the pool
    with no sign that it was ever meant to be there.
    """
    out: dict[str, StationSpec] = {}
    for path in sorted(Path(directory).glob("*.json")):
        spec = load_spec(path)
        if spec.station != path.stem:
            raise SpecError(f"{path}: station {spec.station!r} does not match the filename")
        out[spec.station] = spec
    return out
