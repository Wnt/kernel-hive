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


def emit_fleet_table(rows: list[dict[str, Any]]) -> bytes:
    ledger = _bridge_ledger()
    bridge_tiles = ledger[0]
    entries = []
    for row in sorted(rows, key=lambda r: (r["era_year"], r["id"])):
        tier = _tier(row, bridge_tiles)
        env = row.get("runtime", {}).get("stationEnv") or {}
        museum = row["museum"]
        labctl = row.get("operator", {}).get("labctl") or {}
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
                    ("execKind", labctl.get("exec_kind")),
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
