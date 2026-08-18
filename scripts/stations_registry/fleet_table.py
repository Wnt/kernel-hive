"""Render fleet-table.json: one row per lineup entry with the operator-facing
facts the /fleet view tabulates (tier, emulator, kiosk, I/O paths, memory,
idle-pause, golden scene). Every value is derived from the validated registry
rows plus registry/bridge-suites.json; nothing here is hand-written.

Tier follows docs/GUEST-TIERS.md ("there is no tier field"): empty runtime ->
poster (5); SH_STATION_RUNTIME=x11 -> host-native (3); id in the bridge ledger
-> emulator bridge (2); openvms -> two-QEMU X bridge (4); otherwise direct
QEMU (1). The x11 test comes first on purpose: the ledger still lists the
de-bridged stations, so it is not a kiosk oracle on its own.
"""

from __future__ import annotations

import json
import re
from collections import OrderedDict
from typing import Any

from .constants import REGISTRY
from .loading import RegistryError, is_x11_runtime
from .validate_rules import is_hidden

TIER_LABELS = {
    1: "direct QEMU",
    2: "emulator bridge (kiosk)",
    3: "host-native",
    4: "two-QEMU X bridge (kiosk)",
    5: "showcase poster",
}
IDLE_PAUSE_DEFAULT_SECS = 60  # streamhost/streamhost/src/config/mod.rs env_or("SH_IDLE_PAUSE_SECS", "60")


def _bridge_ledger() -> tuple[dict[str, str], dict[str, dict[str, Any]], str]:
    path = REGISTRY / "bridge-suites.json"
    try:
        doc = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise RegistryError(f"cannot load {path}: {exc}") from exc
    return doc["tiles"], doc["suites"], doc["defaultSuite"]


def _tier(row: dict[str, Any], bridge_tiles: dict[str, str]) -> int:
    runtime = row.get("runtime") or {}
    if not runtime:
        return 5
    if is_x11_runtime(row):
        return 3
    if row["id"] in bridge_tiles:
        return 2
    if row["id"] == "openvms":
        return 4
    return 1


def _kiosk(row: dict[str, Any], tier: int, ledger: tuple[Any, Any, str]) -> dict[str, Any] | None:
    tiles, suites, default = ledger
    if tier not in (2, 4):
        return None
    suite = tiles.get(row["id"], default)
    info = suites.get(suite, {})
    return OrderedDict(
        suite=suite,
        distro=f"Debian {info.get('debianVersion', '?')} ({info.get('codename', suite)})",
        kind="bare-X kiosk VM" if tier == 2 else "lean-Xorg VM + second QEMU (X over SLIRP)",
    )


def _keyboard_path(row: dict[str, Any], tier: int, env: dict[str, str]) -> str | None:
    if tier == 5:
        return None
    backend = env.get("SH_INPUT_BACKEND")
    if backend in ("mamesock", "vicesock"):
        return backend
    if backend == "gallery-hid":
        return "gallery-hid"
    if env.get("SH_WARPD_ADDR"):
        return "warpd agent"
    if tier in (2, 4):
        return "qemu send-key -> kiosk X -> emulator"
    return "qemu send-key (dbus)"


def _pointer_path(row: dict[str, Any], tier: int, env: dict[str, str]) -> dict[str, Any]:
    pointer = row["stream"]["pointer"]
    method = pointer.get("method")
    out: dict[str, Any] = OrderedDict(
        method=method,
        transport=pointer.get("transport"),
        absolute=pointer.get("absolute"),
        present=pointer.get("present"),
        device=pointer.get("device"),
        backend=pointer.get("backend") or env.get("SH_INPUT_BACKEND"),
        scale=pointer.get("scale"),
    )
    if env.get("SH_WARPD_BUTTONS"):
        out["buttons"] = env["SH_WARPD_BUTTONS"]
    if tier in (2, 4) and pointer.get("present"):
        out["via"] = "kiosk X"
    return out


def _capture(row: dict[str, Any], tier: int) -> str | None:
    if tier == 5:
        return None
    if tier == 3:
        return (row.get("runtime", {}).get("x11") or {}).get("capture") or "x11"
    return "dbus"


def _idle_pause(env: dict[str, str]) -> int:
    raw = env.get("SH_IDLE_PAUSE_SECS")
    if raw is None:
        return IDLE_PAUSE_DEFAULT_SECS
    try:
        return int(raw)
    except ValueError:
        return IDLE_PAUSE_DEFAULT_SECS


def _golden(row: dict[str, Any], tier: int, env: dict[str, str]) -> dict[str, Any] | None:
    if tier == 5:
        return None
    reset = row.get("reset") or {}
    x11 = row.get("runtime", {}).get("x11") or {}
    mode = reset.get("resetMode") or x11.get("resetMode") or env.get("SH_RESET_MODE")
    snapshot = reset.get("snapshot") or env.get("SH_GOLDEN_SNAPSHOT")
    if mode == "loadvm":
        kind = "QEMU savevm/loadvm (instant)"
    elif mode == "relaunch":
        kind = "emulator relaunch (checkpoint if the emulator has one)"
    elif mode == "restart":
        kind = "service restart (cold boot, no snapshot)"
    elif mode == "pve-rollback":
        kind = "PVE snapshot rollback"
    else:
        kind = mode
    return OrderedDict(resetMode=mode, snapshot=snapshot, kind=kind, instant=mode == "loadvm")


def _machine(row: dict[str, Any], tier: int) -> dict[str, Any]:
    qemu = row.get("runtime", {}).get("qemu") or {}
    x11 = row.get("runtime", {}).get("x11") or {}
    out: dict[str, Any] = OrderedDict()
    if qemu:
        out["qemuBinary"] = qemu.get("binary")
        out["qemuMachine"] = qemu.get("machine")
        out["accel"] = qemu.get("accel")
        out["vmMemoryMB"] = qemu.get("memoryMB")
        out["smp"] = qemu.get("smp")
        out["vga"] = qemu.get("vga")
    if x11:
        out["geometry"] = x11.get("geometry")
        out["launcher"] = x11.get("launcher")
    if tier == 2:
        out["role"] = "kiosk VM hosting the emulator"
    return out


_NIC_RE = re.compile(
    r"-(netdev|nic|net\b|device (e1000|rtl8139|virtio-net|pcnet|ne2k|i8255|tulip|lance|dp8393|sunhme|usb-net))"
)
_HOSTFWD_RE = re.compile(r"hostfwd=(tcp|udp):[^,\s]+")
_MODEL_RE = re.compile(r"(?:-device |model=)([a-z0-9_-]+)")


def _net(status: str, detail: str, source: str, hostfwd: list[str] | None = None) -> dict[str, Any]:
    return OrderedDict(status=status, detail=detail, hostfwd=hostfwd or [], source=source)


def _network_from_ledger(qemu: dict[str, Any]) -> dict[str, Any]:
    extra = qemu.get("extraArgs") or []
    parts = list(qemu.get("deviceSetSummary") or []) + ([extra] if isinstance(extra, str) else list(extra))
    args = " ".join(str(p) for p in parts)
    net_args = [a for a in re.split(r"\s(?=-)", args) if _NIC_RE.match(a)]
    hostfwd = [m.group(0).removeprefix("hostfwd=") for m in _HOSTFWD_RE.finditer(args)]
    ledger = "device ledger"
    if any("nic none" in a or "net none" in a for a in net_args):
        return _net("none", "-nic none in the device ledger", ledger)
    if not net_args:
        if "-nodefaults" in args:
            return _net("none", "-nodefaults and no NIC in the device ledger", ledger)
        detail = "implicit QEMU default NIC on SLIRP user-mode NAT (no -netdev/-nic in ledger); guest use not recorded"
        return _net("internet", detail, "device ledger (implicit)", hostfwd)
    models = sorted({m.group(1) for a in net_args for m in _MODEL_RE.finditer(a)} - {"user"})
    nic = "/".join(models) if models else "nic"
    if "restrict=on" in args:
        return _net("isolated", f"{nic} on SLIRP restrict=on: link up, nothing reachable", ledger, hostfwd)
    if any("user" in a for a in net_args):
        detail = f"{nic} on SLIRP user-mode NAT (guest reaches out; host reaches in via hostfwd)"
        return _net("internet", detail, ledger, hostfwd)
    if any(("tap" in a or "bridge" in a) for a in net_args):
        return _net("host-only", f"{nic} on a tap/bridge backend", ledger, hostfwd)
    return _net("nic-only", f"{nic}: {' '.join(net_args)}", ledger, hostfwd)


def _network(row: dict[str, Any], tier: int, env: dict[str, str]) -> dict[str, Any] | None:
    """Guest networking as the launcher declares it; a registry `network` block wins.

    Derived from the QEMU device ledger (deviceSetSummary + extraArgs) — a NIC
    on SLIRP, restrict=on, an explicit `-nic none`, or nothing at all (which for
    a stock QEMU machine still means an IMPLICIT default SLIRP NIC unless
    -nodefaults). x11 runtimes only know what their env says (IRIX_NET/TAP).
    A NIC in the ledger is not proof the guest configured it, so the derived
    status is the ledger's word, not the guest's; the declared block exists for
    exactly the cases where the ledger misleads.
    """
    if tier == 5:
        return None
    declared = row.get("network")
    if declared:
        return _net(declared["status"], declared["note"], "registry network block")
    qemu = row.get("runtime", {}).get("qemu") or {}
    if qemu:
        return _network_from_ledger(qemu)
    if env.get("IRIX_NET") == "on":
        egress = env.get("IRIX_NET_EGRESS") == "on"
        tap = f"{env.get('IRIX_TAP_IF', 'tap')} {env.get('IRIX_TAP_HOST_CIDR', '')}"
        tap += f" -> guest {env.get('IRIX_TAP_GUEST_IP', '')}"
        detail = f"host-only tap {tap}" + (" + NAT egress" if egress else "")
        return _net("internet" if egress else "host-only", detail, "station env")
    return _net("none", "no network device declared for this host-native emulator", "station env")


def _exec(row: dict[str, Any], tier: int) -> dict[str, Any] | None:
    """labctl exec: the out-of-band command channel into the guest (operator.labctl)."""
    if tier == 5:
        return None
    labctl = row.get("operator", {}).get("labctl") or {}
    kind = labctl.get("exec_kind")
    if kind in (None, "none"):
        return OrderedDict(kind="none", supported=False, port=None, user=None, detail=labctl.get("notes"))
    return OrderedDict(
        kind=kind,
        supported=True,
        port=labctl.get("exec_port"),
        user=labctl.get("exec_user"),
        detail=labctl.get("notes"),
    )


def emit_fleet_table(rows: list[dict[str, Any]]) -> bytes:
    ledger = _bridge_ledger()
    bridge_tiles = ledger[0]
    entries = []
    for row in sorted(rows, key=lambda r: (r["era_year"], r["id"])):
        tier = _tier(row, bridge_tiles)
        env = row.get("runtime", {}).get("stationEnv") or {}
        museum = row["museum"]
        entries.append(
            OrderedDict(
                [
                    ("id", row["id"]),
                    ("displayName", museum["displayName"]),
                    ("year", museum["year"]),
                    ("era", museum.get("era")),
                    ("lineage", museum.get("lineage")),
                    ("arch", museum.get("arch")),
                    ("guestRamMB", museum.get("ramMB")),
                    ("guestRamKB", museum.get("ramKB")),
                    ("lifecycle", row["lifecycle"]),
                    ("listed", not is_hidden(row) and row["lifecycle"] == "production"),
                    ("tier", tier),
                    ("tierLabel", TIER_LABELS[tier]),
                    ("emulator", row.get("emulator")),
                    ("kiosk", _kiosk(row, tier, ledger)),
                    ("machine", _machine(row, tier)),
                    ("capture", _capture(row, tier)),
                    ("keyboardPath", _keyboard_path(row, tier, env)),
                    ("pointer", _pointer_path(row, tier, env)),
                    ("keyPacingMs", _key_pacing(env)),
                    ("fps", row["stream"].get("fps")),
                    ("audio", row["stream"].get("audio")),
                    ("audioSource", env.get("SH_AUDIO_SOURCE", "dbus") if row["stream"].get("audio") else None),
                    ("idlePauseSecs", None if tier == 5 else _idle_pause(env)),
                    ("golden", _golden(row, tier, env)),
                    ("exec", _exec(row, tier)),
                    ("network", _network(row, tier, env)),
                    ("slot", row["stream"].get("slot")),
                    ("guestDoc", row.get("guestDoc")),
                ]
            )
        )
    doc = OrderedDict(
        [
            ("_generated", "scripts/stations-registry.py render; DO NOT EDIT"),
            ("schemaVersion", 1),
            ("tierLabels", {str(k): v for k, v in TIER_LABELS.items()}),
            ("entries", entries),
        ]
    )
    return (json.dumps(doc, indent=2, ensure_ascii=False) + "\n").encode()


def _key_pacing(env: dict[str, str]) -> dict[str, int] | None:
    hold, gap = env.get("SH_KEY_MIN_HOLD_MS"), env.get("SH_KEY_MIN_GAP_MS")
    if hold is None and gap is None:
        return None
    return OrderedDict(holdMs=int(hold or 0), gapMs=int(gap or 0))
