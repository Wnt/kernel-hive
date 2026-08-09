#!/usr/bin/env python3
"""Validate and generate all tile lineup artifacts from registry/tiles/*.json."""

from __future__ import annotations

import argparse
import ast
import difflib
import json
import os
import re
import shlex
import sys
import tempfile
from collections import OrderedDict
from datetime import date
from pathlib import Path
from typing import Any

from poster_registry import PosterError, load_posters

REPO = Path(__file__).resolve().parents[1]
REGISTRY = REPO / "registry"
TILES = REGISTRY / "tiles"
TEMPLATES = REGISTRY / "templates"
POSTERS = REGISTRY / "posters"

# Generated shell artifacts excluded from shfmt/shellcheck (scripts/lint/shell-sources.sh):
# their bytes are owned by the generator, not hand-formatted. Kept here so the
# gate-list meta-check can assert the exclusion list has not rotted.
GENERATED_SHELL = frozenset(
    (
        "scripts/build-guests/build-all.sh",
        "streamhost/tiles-manifest.sh",
        "streamhost/bring-up-all.sh",
    )
)

LABCTL_KEYS = (
    "dir",
    "qmp",
    "pointer_mode",
    "warpd_port",
    "warpd_addr",
    "ssh_port",
    "exec_port",
    "exec_kind",
    "exec_user",
    "exec_key",
    "console",
    "udp_port",
    "notes",
)
NEW_TILE_SLOT_FLOOR = 81


class RegistryError(Exception):
    pass


def is_x11_runtime(row: dict[str, Any]) -> bool:
    """True for the non-QEMU x11 streamhost runtime (SH_CAPTURE=x11 tiles).

    Discriminated by a runtime.x11 block; the tileEnv carries the matching
    SH_TILE_RUNTIME=x11 marker the service dispatch keys on. The block is still
    called `x11` because that names the RUNTIME (an emulator managed by
    x11-runtime.sh rather than a QEMU VM). Its FRAME SOURCE is chosen separately
    by runtime.x11.capture and may be `shm`, in which case no X server is
    involved at all.
    """
    return "x11" in row.get("runtime", {})


def load() -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        globals_doc = json.loads((REGISTRY / "registry-v1.json").read_text(), object_pairs_hook=OrderedDict)
    except (OSError, json.JSONDecodeError) as exc:
        raise RegistryError(f"cannot load registry/registry-v1.json: {exc}") from exc
    rows = []
    for path in sorted(TILES.glob("*.json")):
        try:
            row = json.loads(path.read_text(), object_pairs_hook=OrderedDict)
        except json.JSONDecodeError as exc:
            raise RegistryError(f"{path.relative_to(REPO)}:{exc.lineno}: {exc.msg}") from exc
        row["_path"] = path
        rows.append(row)
    if not rows:
        raise RegistryError("registry/tiles contains no entries")
    return globals_doc, rows


def scan_value(text: str, start: int) -> tuple[str, int]:
    quote = None
    escaped = False
    depth = 0
    i = start
    while i < len(text):
        c = text[i]
        if quote:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == quote:
                quote = None
        elif c in "'\"`":
            quote = c
        elif c in "[{(":
            depth += 1
        elif c in "]})":
            if depth == 0:
                break
            depth -= 1
        elif c == "," and depth == 0:
            break
        i += 1
    return text[start:i].strip(), i


def js_value(raw: str) -> Any:
    raw = raw.strip()
    if raw in {"true", "false", "null"}:
        return {"true": True, "false": False, "null": None}[raw]
    if re.fullmatch(r"-?\d+(?:\.\d+)?", raw):
        return float(raw) if "." in raw else int(raw)
    return ast.literal_eval(raw)


def parse_js_object(source: str) -> OrderedDict[str, Any]:
    start, end = source.find("{"), source.rfind("}")
    if start < 0 or end <= start:
        raise RegistryError("cannot parse TypeScript object render block")
    text = source[start + 1 : end]
    out: OrderedDict[str, Any] = OrderedDict()
    i = 0
    while i < len(text):
        while i < len(text) and (text[i].isspace() or text[i] == ","):
            i += 1
        if i >= len(text):
            break
        if text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                break
            continue
        if text[i] in "'\"":
            q, j = text[i], i + 1
            while j < len(text):
                if text[j] == q and text[j - 1] != "\\":
                    break
                j += 1
            key = str(js_value(text[i : j + 1]))
            i = j + 1
        else:
            m = re.match(r"[A-Za-z_$][A-Za-z0-9_$-]*", text[i:])
            if not m:
                raise RegistryError(f"bad TypeScript object key near {text[i : i + 40]!r}")
            key = m.group(0)
            i += len(key)
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text) or text[i] != ":":
            raise RegistryError(f"missing colon after TypeScript key {key}")
        i += 1
        while i < len(text) and text[i].isspace():
            i += 1
        raw, i = scan_value(text, i)
        out[key] = js_value(raw)
    return out


def fail(errors: list[str], row: dict[str, Any], message: str) -> None:
    path = row.get("_path", "<entry>")
    if isinstance(path, Path):
        path = path.relative_to(REPO)
    errors.append(f"{path}: {message}")


def validate_json_schema(value: Any, schema: dict[str, Any], where: str, errors: list[str]) -> None:
    """Dependency-free evaluator for the schema keywords used by tile-v1."""
    expected = schema.get("type")
    type_map = {
        "object": lambda x: isinstance(x, dict),
        "array": lambda x: isinstance(x, list),
        "string": lambda x: isinstance(x, str),
        "integer": lambda x: isinstance(x, int) and not isinstance(x, bool),
        "number": lambda x: isinstance(x, (int, float)) and not isinstance(x, bool),
        "boolean": lambda x: isinstance(x, bool),
    }
    if expected and not type_map[expected](value):
        errors.append(f"{where}: expected {expected}, got {type(value).__name__}")
        return
    if "const" in schema and value != schema["const"]:
        errors.append(f"{where}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{where}: {value!r} is not one of {schema['enum']!r}")
    if isinstance(value, str) and "pattern" in schema and not re.fullmatch(schema["pattern"], value):
        errors.append(f"{where}: {value!r} does not match {schema['pattern']}")
    if (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and "minimum" in schema
        and value < schema["minimum"]
    ):
        errors.append(f"{where}: {value} is below minimum {schema['minimum']}")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{where}: missing required property {key}")
        for key, child in schema.get("properties", {}).items():
            if key in value:
                validate_json_schema(value[key], child, f"{where}.{key}", errors)
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            validate_json_schema(item, schema["items"], f"{where}[{index}]", errors)


def validate_schema_shape(rows: list[dict[str, Any]], errors: list[str]) -> None:
    lifecycle = {"production", "experiment", "showcase", "candidate"}
    transports = {"streamhost", "showcase"}
    pointers = {"abs", "rel", "warpd", "none"}
    for row in rows:
        for key in (
            "schemaVersion",
            "id",
            "era_year",
            "lifecycle",
            "enabled",
            "stream",
            "museum",
            "spa",
            "operator",
            "build",
            "render",
        ):
            if key not in row:
                fail(errors, row, f"missing required field {key}")
        if row.get("schemaVersion") != 1:
            fail(errors, row, "schemaVersion must be 1")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", str(row.get("id", ""))):
            fail(errors, row, "id must match [a-z0-9][a-z0-9-]*")
        if row.get("lifecycle") not in lifecycle:
            fail(errors, row, f"invalid lifecycle {row.get('lifecycle')!r}")
        stream = row.get("stream", {})
        if stream.get("transport") not in transports:
            fail(errors, row, f"invalid stream.transport {stream.get('transport')!r}")
        if stream.get("transport") == "streamhost":
            for key in ("tileDir", "udpPort", "fps", "audio", "touch", "pointer"):
                container = row if key == "tileDir" else stream
                if key not in container:
                    fail(errors, row, f"streamhost entry missing {key}")
            if stream.get("pointer", {}).get("transport") not in pointers:
                fail(errors, row, "invalid pointer transport")
            runtime = row.get("runtime", {})
            # x11 tiles are the non-QEMU streamhost runtime (issue #20 / IRIX):
            # an Xvfb+emulator captured via SH_CAPTURE=x11. They carry a
            # runtime.x11 block instead of runtime.qemu and are validated apart.
            if is_x11_runtime(row):
                x11 = runtime.get("x11", {})
                for key in ("display", "geometry", "launcher", "resetMode"):
                    if key not in x11:
                        fail(errors, row, f"runtime.x11 missing {key}")
                if x11.get("resetMode") not in {"relaunch", "criu"}:
                    fail(errors, row, f"invalid runtime.x11.resetMode {x11.get('resetMode')!r}")
                if "qemu" in runtime:
                    fail(errors, row, "x11 runtime must not also declare runtime.qemu")
                museum = row.get("museum", {})
                for key in ("id", "displayName", "year", "lineage", "arch", "accent"):
                    if key not in museum:
                        fail(errors, row, f"museum missing {key}")
                continue
            qemu = runtime.get("qemu", {})
            for key in ("mode", "deviceSetId", "deviceSetSummary"):
                if key not in qemu:
                    fail(errors, row, f"runtime.qemu missing {key}")
            mode = qemu.get("mode")
            if mode not in {"generic", "verbatim", "pve"}:
                fail(errors, row, f"invalid runtime.qemu.mode {mode!r}")
            if mode == "pve":
                vmid = runtime.get("pve", {}).get("vmid")
                if not isinstance(vmid, int) or isinstance(vmid, bool) or vmid < 1:
                    fail(errors, row, "pve runtime.qemu requires runtime.pve.vmid >= 1")
                if "launcher" in qemu:
                    fail(errors, row, "pve runtime.qemu forbids launcher")
            else:
                for key in ("binary", "accel", "vga"):
                    if key not in qemu:
                        fail(errors, row, f"runtime.qemu missing {key}")
            if qemu.get("mode") == "verbatim" and "launcher" not in qemu:
                fail(errors, row, "verbatim runtime.qemu missing launcher")
            parity = qemu.get("launcherParity", {})
            if parity.get("status") not in {"byte-identical", "semantic-identical", "hand-managed"}:
                fail(errors, row, "runtime.qemu.launcherParity has invalid/missing status")
        museum = row.get("museum", {})
        for key in ("id", "displayName", "year", "lineage", "arch", "accent"):
            if key not in museum:
                fail(errors, row, f"museum missing {key}")
        demo = row.get("demoProgram")
        if demo is not None:
            if not demo.get("label", "").strip() or not demo.get("runCommand", "").strip():
                fail(errors, row, "demoProgram needs a non-empty label and runCommand")
            lines = demo.get("lines", [])
            if not lines or any(not isinstance(line, str) or not line.strip() for line in lines):
                fail(errors, row, "demoProgram.lines must be a non-empty list of non-blank strings")


# spa/src/ui/grid/StreamView/typeDemoProgram.ts DEMO_PER_CHAR_MS -- what the SPA
# typist assumes when the entry declares no perCharMs of its own.
SPA_DEFAULT_PER_CHAR_MS = 70


def validate_demo_pacing(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """The typist's per-character budget must not undercut the daemon's pacing.

    streamhost drains typed keys at SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS per
    character. The SPA waits line.length * perCharMs before submitting the next
    line, so a perCharMs below that rate builds a backlog across the listing: the
    ENTER arrives late and the next line's first characters land while BASIC is
    still tokenising, which the visitor sees as randomly missing characters. The
    two numbers live in different files, so pin them together here rather than
    rediscovering the drift on the exhibit floor.
    """
    for row in rows:
        demo = row.get("demoProgram")
        if not demo:
            continue
        env = (row.get("runtime") or {}).get("tileEnv", {})

        def ms(key: str, env: dict[str, Any] = env) -> int:
            try:
                return int(env.get(key, 0))
            except (TypeError, ValueError):
                return 0

        drain = ms("SH_KEY_MIN_HOLD_MS") + ms("SH_KEY_MIN_GAP_MS")
        if drain == 0:
            continue
        budget = demo.get("perCharMs", SPA_DEFAULT_PER_CHAR_MS)
        if budget < drain:
            fail(
                errors,
                row,
                f"demoProgram.perCharMs={budget} is below the tile's typed drain rate "
                f"({drain} ms/char = SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS); the typist "
                f"would out-run the guest and lose characters",
            )


def keymap_escape(ch: str) -> str:
    """Percent-encode the three characters SH_KEY_MAP's wire format cannot carry.

    The value is `guest:host` pairs joined by commas, so a guest or host
    character that IS a colon or a comma has no literal spelling: the Dragon 32
    puts ':' on the host key a PC labels '-', which would render as `::-`, and
    labctl's split(':', 1) then yields an empty guest and DROPS the mapping
    silently -- one missing character, not an error. Only '%', ',' and ':' are
    touched, so every map written before this existed renders unchanged;
    labctl's keymap_unescape() is the other half.
    """
    return ch.replace("%", "%25").replace(",", "%2C").replace(":", "%3A")


def validate_keyboard_env(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """`keyboard.charMap` is the single source; SH_KEY_MAP is how labctl consumes it.

    labctl drives QMP directly and cannot read the registry, so the map reaches it
    through the tile's env. Two copies can drift, and a drifted keyboard map fails
    as mangled characters that read like a timing bug -- so pin them together here.
    """
    for row in rows:
        charmap = (row.get("keyboard") or {}).get("charMap")
        env = (row.get("runtime") or {}).get("tileEnv", {}).get("SH_KEY_MAP")
        if not charmap and not env:
            continue
        if charmap and not env:
            fail(
                errors,
                row,
                "keyboard.charMap declared but SH_KEY_MAP missing from runtime.tileEnv (labctl reads it from there)",
            )
            continue
        if env and not charmap:
            fail(errors, row, "SH_KEY_MAP set in runtime.tileEnv with no keyboard.charMap to derive it from")
            continue
        expected = ",".join(f"{keymap_escape(g)}:{keymap_escape(h)}" for g, h in charmap.items())
        if env != expected:
            fail(errors, row, f"SH_KEY_MAP does not match keyboard.charMap (expected {expected!r}, found {env!r})")


def validate_fleet_encoder(globals_doc: dict[str, Any], errors: list[str]) -> None:
    """Pin the emitter's fleet default to the value the registry declares.

    SH_BUFSIZE_RATIO=0.5 was applied by hand across the fleet on 2026-07-17 and
    never recorded in the registry, so a re-emit would have silently restored 1.0
    on 30 tiles. The emitter writes the value; the registry now declares it; this
    stops the two from disagreeing again. (It changes no behaviour today: tier 0
    is CQP with no VBV and the daemon already caps ABR tiers at min(ratio, 0.5) --
    but a silent divergence between what the registry says and what the fleet runs
    is the thing worth preventing.)
    """
    declared = (globals_doc.get("fleetEncoder") or {}).get("bufsizeRatio")
    if declared is None:
        return
    emitter = REPO / "streamhost/scripts/streamhost-tile.sh"
    text = emitter.read_text()
    found = re.search(r'^BUFSIZE_RATIO="([0-9.]+)"', text, re.M)
    if not found:
        errors.append(f"{emitter.relative_to(REPO)}: cannot find the BUFSIZE_RATIO default")
    elif float(found.group(1)) != float(declared):
        errors.append(
            f"{emitter.relative_to(REPO)}: BUFSIZE_RATIO default {found.group(1)} != "
            f"registry-v1.json fleetEncoder.bufsizeRatio {declared}"
        )


def validate_exhibit_assets(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """A production tile is not an exhibit until it has a placard and a hero image.

    Both were missing when mpf2 first went to `lifecycle: production`, and nothing
    caught it -- the SPA simply rendered a tile with no exhibit notes. These live
    outside the registry (prose in registry/posters/, the image in the SPA's public
    tree), so only a filesystem check can see them.
    """
    for row in rows:
        if row.get("lifecycle") != "production" or not row.get("enabled"):
            continue
        if row.get("stream", {}).get("transport") != "streamhost":
            continue
        os_id = row["id"]
        if not (REGISTRY / "posters" / f"{os_id}.md").is_file():
            fail(errors, row, f"production tile has no poster prose: registry/posters/{os_id}.md")
        hero = REPO / "spa/public/posters" / os_id / "desktop.webp"
        if not hero.is_file():
            fail(errors, row, f"production tile has no hero image: {hero.relative_to(REPO)}")


def validate() -> tuple[dict[str, Any], list[dict[str, Any]]]:
    globals_doc, rows = load()
    errors: list[str] = []
    try:
        schema = json.loads((REGISTRY / "schema/tile-v1.schema.json").read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise RegistryError(f"cannot load tile JSON Schema: {exc}") from exc
    for row in rows:
        validate_json_schema(
            {k: v for k, v in row.items() if k != "_path"}, schema, str(row["_path"].relative_to(REPO)), errors
        )
    validate_schema_shape(rows, errors)
    validate_exhibit_assets(rows, errors)
    validate_keyboard_env(rows, errors)
    validate_demo_pacing(rows, errors)
    validate_fleet_encoder(globals_doc, errors)
    ids: dict[str, str] = {}
    unique: dict[str, dict[Any, str]] = {
        k: {} for k in ("tileDir", "udpPort", "slot", "experimentSlot", "bringUpOrder", "bindingOrder")
    }
    by_id = {row["id"]: row for row in rows}
    for row in rows:
        os_id = row["id"]
        expected_name = f"{os_id}.json"
        if row["_path"].name != expected_name:
            fail(errors, row, f"filename must be {expected_name}")
        if os_id in ids:
            fail(errors, row, f"duplicate id also in {ids[os_id]}")
        ids[os_id] = str(row["_path"])
        if row.get("museum", {}).get("id") != os_id:
            fail(errors, row, "museum.id differs from id")
        stream = row.get("stream", {})
        runtime = row.get("runtime", {})
        render = row.get("render", {})
        binding_order = render.get("bindingOrder")
        if row.get("enabled") and (
            not isinstance(binding_order, int) or isinstance(binding_order, bool) or binding_order < 0
        ):
            fail(errors, row, "enabled entry render.bindingOrder must be a non-negative integer")
        # Disabled candidate scaffolds reserve their identity, slot, and port even
        # though they intentionally use showcase transport until promotion.
        for key, value in (
            ("tileDir", row.get("tileDir")),
            ("udpPort", stream.get("udpPort")),
            ("slot", stream.get("slot")),
            ("experimentSlot", stream.get("experimentSlot")),
            ("bringUpOrder", runtime.get("bringUpOrder")),
            ("bindingOrder", binding_order),
        ):
            if value is None:
                continue
            if value in unique[key]:
                fail(errors, row, f"duplicate {key}={value!r} also used by {unique[key][value]}")
            unique[key][value] = os_id
        if stream.get("transport") != "streamhost":
            if row.get("lifecycle") not in {"showcase", "candidate"}:
                fail(errors, row, "non-streamhost entry must be showcase/candidate")
            continue
        if row.get("lifecycle") == "production":
            if stream.get("legacyPortException"):
                if stream.get("udpPort") == globals_doc["ports"]["productionBase"] + stream.get("slot", -1):
                    fail(errors, row, "legacyPortException set but port follows slot policy")
            elif stream.get("udpPort") != globals_doc["ports"]["productionBase"] + stream.get("slot", -99999):
                fail(errors, row, "production UDP port violates base+slot policy without legacyPortException")
            for key in ("tilesManifestOrder", "bringUpGroup", "goldenOrder"):
                if key not in row.get("render", {}):
                    fail(errors, row, f"production entry missing render.{key}")
            if runtime.get("bringUpOrder") is None:
                fail(errors, row, "production entry missing bringUpOrder")
            if "reset" not in row:
                fail(errors, row, "production entry missing reset policy")
            # A tile outside the edge's DNAT range is unreachable from the public
            # gallery while looking entirely healthy on the box -- service active,
            # ticket accepted, signalling fine, and the daemon simply never sees a
            # session. Four tiles shipped that way on 2026-08-09.
            low = globals_doc["ports"]["publicRelayLow"]
            high = globals_doc["ports"]["publicRelayHigh"]
            # legacyPortException tiles are deliberately off the base+slot policy
            # (reactos sits on 4433) and the edge carries its own rule for them, so
            # the range check does not apply.
            in_range = low <= stream.get("udpPort", -1) <= high
            if stream.get("transport") == "streamhost" and not stream.get("legacyPortException") and not in_range:
                fail(
                    errors,
                    row,
                    f"udpPort {stream.get('udpPort')} is outside the public relay range "
                    f"{low}-{high}: the tile would stream on the LAN but be unreachable "
                    f"through the edge. Widen the range (nftables on vm-control, the "
                    f"comment in /etc/wireguard/wg0.conf and docs/PUBLIC-GALLERY.md) or "
                    f"pick a slot inside it.",
                )
        elif row.get("lifecycle") == "experiment":
            expected = globals_doc["ports"]["experimentBase"] + stream.get("experimentSlot", -99999)
            if stream.get("udpPort") != expected:
                fail(errors, row, "experiment UDP port violates base+experimentSlot policy")
        tile_dir = row["tileDir"]
        aliases = row.get("aliases")
        if os_id != tile_dir and aliases != {"publicId": os_id, "tileDir": tile_dir}:
            fail(errors, row, "public/tile alias must be explicit")
        ptr = stream["pointer"]
        if (
            ptr["transport"] == "rel"
            and not row.get("spa", {}).get("pointerRel")
            and "spa-pointer-rel" not in row.get("migrationExceptions", [])
        ):
            fail(errors, row, "relative pointer lacks SPA pointerRel or spa-pointer-rel migration exception")
        if ptr["transport"] == "warpd" and "agentAddress" not in ptr:
            fail(errors, row, "warpd pointer missing agentAddress")
        x11 = is_x11_runtime(row)
        qemu = runtime.get("qemu", {})
        machine = qemu.get("machine")
        if (
            not x11
            and (
                machine is None or machine in {"pc", "q35"} or (isinstance(machine, str) and machine.startswith("pc,"))
            )
            and "legacy-machine-alias" not in row.get("migrationExceptions", [])
        ):
            fail(errors, row, "unversioned/implicit production machine lacks legacy-machine-alias exception")
        if qemu.get("patchedDevice") == "gallery-hid-pci":
            binary = qemu.get("binary", "")
            stable_binary = "/data/vms/streamhost/qemu-gallery-hid/qemu-system-x86_64"
            if not (binary.startswith("/data/vms/soltest/") or binary == stable_binary):
                fail(errors, row, "gallery-hid must use the standalone patched QEMU")
            companions = {item.get("name") for item in runtime.get("companions", [])}
            native_sink = runtime.get("tileEnv", {}).get("SH_INPUT_BACKEND") == "gallery-hid"
            if not native_sink and "warpd-to-ghid" not in companions:
                fail(errors, row, "gallery-hid missing warpd-to-ghid companion")
            if native_sink and "warpd-to-ghid" in companions:
                fail(errors, row, "native gallery-hid sink must not declare the Python bridge companion")
        reset = row.get("reset")
        if reset:
            if reset.get("resetMode") == "loadvm" and not reset.get("snapshot"):
                fail(errors, row, "loadvm reset missing snapshot")
            if reset.get("resetMode") == "restart" and reset.get("snapshot") is not None:
                fail(errors, row, "restart reset must have null snapshot")
            if reset.get("resetMode") == "pve-rollback":
                if qemu.get("mode") != "pve":
                    fail(errors, row, "pve-rollback reset requires runtime.qemu.mode pve")
                if reset.get("snapshot") != "golden":
                    fail(errors, row, "pve-rollback reset snapshot must be golden")
            # relaunch (x11 RAM-overlay pristine reboot) has no snapshot; criu
            # restores a checkpointed container/desktop tagged 'golden'.
            if reset.get("resetMode") == "relaunch" and reset.get("snapshot") is not None:
                fail(errors, row, "relaunch reset must have null snapshot")
            if reset.get("resetMode") == "criu" and reset.get("snapshot") != "golden":
                fail(errors, row, "criu reset snapshot must be golden")
            if x11 and reset.get("resetMode") not in {"relaunch", "criu"}:
                fail(errors, row, "x11 tile reset must be relaunch or criu")
        env = runtime.get("tileEnv", {})
        expected_env = {
            "SH_TILE": tile_dir,
            "SH_PORT": str(stream["udpPort"]),
            "SH_FPS": str(stream["fps"]),
            "SH_AUDIO": "on" if stream["audio"] else "off",
        }
        if "backend" in ptr:
            expected_env["SH_INPUT_BACKEND"] = ptr["backend"]
            if "SH_POINTER" in env:
                fail(errors, row, "unified pointer backend must not also emit legacy SH_POINTER")
        else:
            expected_env["SH_POINTER"] = ptr["transport"]
        if qemu.get("mode") == "pve":
            vmid = runtime.get("pve", {}).get("vmid")
            if isinstance(vmid, int) and not isinstance(vmid, bool) and vmid >= 1:
                expected_env.update(
                    {
                        "SH_QEMU_MODE": "pve",
                        "SH_PVE_VMID": str(vmid),
                        "SH_QEMU_PIDFILE": f"/var/run/qemu-server/{vmid}.pid",
                    }
                )
                emit_args = qemu.get("emitArgs", [])
                if "--pve-vmid" not in emit_args or str(vmid) not in emit_args:
                    fail(errors, row, "pve runtime.qemu.emitArgs must include --pve-vmid and runtime.pve.vmid")
        if x11:
            x11cfg = runtime.get("x11", {})
            # The frame SOURCE is independent of the runtime kind: `x11` grabs
            # an Xvfb root, `shm` maps a framebuffer the emulator publishes
            # itself (no window, no X server). Default x11, so a tile that does
            # not declare one is unchanged.
            capture = x11cfg.get("capture", "x11")
            expected_env.update(
                {
                    "SH_CAPTURE": capture,
                    "SH_X11_DISPLAY": x11cfg.get("display"),
                    "SH_TILE_RUNTIME": "x11",
                    "SH_X11_CMD_FILE": f"/data/vms/streamhost/tiles/{tile_dir}/irix_cmd",
                }
            )
            if capture == "shm":
                expected_env["SH_SHM_PATH"] = f"/data/vms/streamhost/tiles/{tile_dir}/fb.shm"
            if "SH_QMP" in env:
                fail(errors, row, "x11 tile must not emit SH_QMP (no QEMU/QMP)")
        for key, value in expected_env.items():
            if env.get(key) != value:
                fail(errors, row, f"tileEnv {key}={env.get(key)!r}, expected {value!r}")
        for ref in (row.get("guestDoc"), qemu.get("launcher"), qemu.get("envFixture")):
            if ref and not (REPO / ref).exists():
                fail(errors, row, f"referenced path does not exist: {ref}")
        for ref in list(qemu.get("auxFiles", [])) + list(runtime.get("x11", {}).get("auxFiles", [])):
            if not (REPO / ref).exists():
                fail(errors, row, f"referenced aux path does not exist: {ref}")
        x11_launcher = runtime.get("x11", {}).get("launcher")
        if x11_launcher and not (REPO / x11_launcher).exists():
            fail(errors, row, f"referenced path does not exist: {x11_launcher}")
        if not re.fullmatch(r"guest/[a-z0-9-]+", row.get("credentialsRef", "")):
            fail(errors, row, "credentialsRef must be an opaque guest/<id> reference")
        render = row.get("render", {})
        for item in row.get("build", {}).get("rows", []):
            match = re.fullmatch(r'  "([^\n"]+)"\n', item.get("line", ""))
            if not match:
                fail(errors, row, "build render line has unsupported format")
                continue
            columns = [part.strip() for part in match.group(1).split("|")]
            parsed_build = {
                "key": columns[0],
                "script": columns[1],
                "outputDir": columns[2],
                "class": columns[3],
                "estimated": columns[4],
                "automation": columns[5],
                "produces": columns[6],
                "flags": columns[7:],
            }
            if parsed_build != item.get("value"):
                fail(errors, row, f"rendered build row {columns[0]} disagrees with typed fields")
        if "tilesManifestInvocation" in render:
            tokens = shlex.split(render["tilesManifestInvocation"].replace("\\\n", " "))
            expected_emit = runtime.get("x11", {}).get("emitArgs") if x11 else qemu.get("emitArgs")
            if tokens[:2] != ["emit", tile_dir] or tokens[2:] != expected_emit:
                fail(errors, row, "rendered emit invocation disagrees with runtime emitArgs")
        if "bindingLine" in render:
            parsed = parse_js_object(render["bindingLine"])
            if parsed.pop("osId", None) != os_id or dict(parsed) != dict(row.get("spa", {})):
                fail(errors, row, "rendered OS binding disagrees with spa fields")
        if "museumBlock" in render and dict(parse_js_object(render["museumBlock"])) != dict(row["museum"]):
            fail(errors, row, "rendered museum block disagrees with museum fields")
        if "catalogBlock" in render:
            parsed = parse_js_object(render["catalogBlock"])
            curated = {
                k: row["museum"][k] for k in ("accent", "era", "eraSoftware", "periodBrowser", "iconicApps", "blurb")
            }
            if dict(parsed) != curated:
                fail(errors, row, "rendered catalog adapter block disagrees with museum fields")
    if set(by_id) != {p.stem for p in TILES.glob("*.json")}:
        errors.append("registry filename/id set mismatch")
    for item in globals_doc.get("sharedBuildRows", []):
        match = re.fullmatch(r'  "([^\n"]+)"\n', item.get("line", ""))
        if not match:
            errors.append("registry/registry-v1.json: shared build render line has unsupported format")
            continue
        columns = [part.strip() for part in match.group(1).split("|")]
        parsed = {
            "key": columns[0],
            "script": columns[1],
            "outputDir": columns[2],
            "class": columns[3],
            "estimated": columns[4],
            "automation": columns[5],
            "produces": columns[6],
            "flags": columns[7:],
        }
        if parsed != item.get("value"):
            errors.append(f"registry/registry-v1.json: shared build row {columns[0]} disagrees with typed fields")
    if errors:
        raise RegistryError("validation failed:\n  - " + "\n  - ".join(errors))
    return globals_doc, rows


def template(name: str, marker: str, value: str) -> bytes:
    source = (TEMPLATES / name).read_text()
    if source.count(marker) != 1:
        raise RegistryError(f"template {name} must contain {marker} exactly once")
    return source.replace(marker, value).encode()


def apply_count_tokens(data: bytes, rows: list[dict[str, Any]]) -> bytes:
    counts = {
        b"@@LINEUP_COUNT@@": len(rows),
        b"@@PRODUCTION_COUNT@@": sum(r["lifecycle"] == "production" for r in rows),
        b"@@STREAMED_COUNT@@": sum(r["stream"]["transport"] == "streamhost" for r in rows),
        b"@@SHOWCASE_COUNT@@": sum(r["lifecycle"] == "showcase" for r in rows),
        b"@@MUSEUM_ENTRY_COUNT@@": sum("museumBlock" in r["render"] for r in rows),
        b"@@STREAMED_MUSEUM_ENTRY_COUNT@@": sum(
            r["stream"]["transport"] == "streamhost" and "museumBlock" in r["render"] for r in rows
        ),
    }
    for token, count in counts.items():
        data = data.replace(token, str(count).encode())
    unresolved = sorted(set(re.findall(rb"@@[A-Z0-9_]+@@", data)))
    if unresolved:
        raise RegistryError(f"unresolved template tokens: {unresolved}")
    return data


def render_mock(rows: list[dict[str, Any]]) -> bytes:
    selected = sorted(
        (r for r in rows if "mockManifestOrder" in r["render"]), key=lambda r: r["render"]["mockManifestOrder"]
    )
    lines = ["["]
    for index, row in enumerate(selected):
        lines.append("  {")
        items = list(row["museum"].items())
        for i, (key, value) in enumerate(items):
            comma = "," if i + 1 < len(items) else ""
            encoded = json.dumps(value, ensure_ascii=False)
            lines.append(f"    {json.dumps(key)}: {encoded}{comma}")
        lines.append("  }" + ("," if index + 1 < len(selected) else ""))
    lines.append("]")
    return ("\n".join(lines) + "\n").encode()


def render_posters(posters: OrderedDict[str, dict[str, Any]]) -> bytes:
    encoded = json.dumps(posters, indent=2, ensure_ascii=False)
    return (
        "// DO NOT EDIT — generated by scripts/tiles-registry.py generate from\n"
        "// registry/posters/*.md; run `make tile-registry-generate`.\n"
        "import type { PosterDoc } from '../types';\n\n"
        f"export const POSTERS = {encoded} as const satisfies Record<string, PosterDoc>;\n\n"
        "export function posterFor(osId: string): PosterDoc | undefined {\n"
        "  return POSTERS[osId as keyof typeof POSTERS];\n"
        "}\n"
    ).encode()


def render_keyboards(rows: list[dict[str, Any]]) -> bytes:
    """Emit how each machine's keyboard differs from a PC's.

    typeText() maps ASCII to US set1 scancodes -- it presses the key a US PC
    keyboard would. A guest whose matrix disagrees silently receives a different
    character: the MPF-II puts '=' on Shift+O and '-' on Shift+I (a PC's own '='
    and '-' keys are absent from its matrix, so those characters VANISH), and its
    shifted number row is offset by one. Derive a tile's map with
    scripts/dev/mame-keymap.py rather than inferring it from a mangled screen.
    """
    boards = OrderedDict(
        (row["id"], row["keyboard"]) for row in sorted(rows, key=lambda r: r["id"]) if "keyboard" in row
    )
    encoded = json.dumps(boards, indent=2, ensure_ascii=False)
    return (
        "// DO NOT EDIT — generated by scripts/tiles-registry.py generate from\n"
        "// registry/tiles/*.json (keyboard); run `make tile-registry-generate`.\n"
        "import type { GuestKeyboard } from '../types';\n\n"
        f"const KEYBOARDS = {encoded} as const satisfies Record<string, GuestKeyboard>;\n\n"
        "export function keyboardFor(osId: string): GuestKeyboard | undefined {\n"
        "  return KEYBOARDS[osId as keyof typeof KEYBOARDS];\n"
        "}\n"
    ).encode()


def render_demo_programs(rows: list[dict[str, Any]]) -> bytes:
    """Emit the per-tile type-in listings the SPA can key into a live guest."""
    programs = OrderedDict(
        (row["id"], row["demoProgram"]) for row in sorted(rows, key=lambda r: r["id"]) if "demoProgram" in row
    )
    encoded = json.dumps(programs, indent=2, ensure_ascii=False)
    return (
        "// DO NOT EDIT — generated by scripts/tiles-registry.py generate from\n"
        "// registry/tiles/*.json (demoProgram); run `make tile-registry-generate`.\n"
        "import type { DemoProgram } from '../types';\n\n"
        f"const DEMO_PROGRAMS = {encoded} as const satisfies Record<string, DemoProgram>;\n\n"
        "export function demoProgramFor(osId: string): DemoProgram | undefined {\n"
        "  return DEMO_PROGRAMS[osId as keyof typeof DEMO_PROGRAMS];\n"
        "}\n"
    ).encode()


def emit_gallery_manifest(rows: list[dict[str, Any]]) -> bytes:
    """Emit the public, runtime SPA lineup without operational/private fields."""
    entries = []
    selected = (r for r in rows if r.get("enabled") and "bindingOrder" in r["render"])
    for row in sorted(selected, key=lambda r: r["render"]["bindingOrder"]):
        museum = row["museum"]
        spa = row["spa"]
        label_suffix = spa["eraLabel"].split(" · ", 1)[-1]
        entry = OrderedDict(
            [
                ("id", row["id"]),
                ("era_year", row["era_year"]),
                ("displayName", museum["displayName"]),
                ("year", museum["year"]),
                ("lineage", museum["lineage"]),
                ("arch", museum["arch"]),
                ("accent", museum["accent"]),
                ("archetypeId", spa["archetypeId"]),
                ("transport", spa["transport"]),
                ("order", row["render"]["bindingOrder"]),
                ("eraLabel", f"{museum['year']} · {label_suffix}"),
                ("signalEndpoint", f"/signal/{row['id']}.json" if spa["transport"] == "streamhost" else None),
            ]
        )
        for key in ("ramMB", "ramKB", "notes", "era", "eraSoftware", "periodBrowser", "iconicApps", "blurb"):
            if key in museum:
                entry[key] = museum[key]
        for key in ("endpoint", "pointerRel", "hardwareInput", "coldBoot", "bootVideo"):
            if key in spa:
                entry[key] = spa[key]
        entries.append(entry)

    document = OrderedDict(
        [
            ("_generated", "scripts/tiles-registry.py generate; PUBLIC DATA ONLY; DO NOT EDIT"),
            ("schemaVersion", 1),
            ("entries", entries),
        ]
    )
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode()


def generated() -> OrderedDict[str, bytes]:
    globals_doc, rows = validate()
    try:
        posters, poster_warnings = load_posters(POSTERS, {row["id"] for row in rows})
    except (OSError, PosterError) as exc:
        raise RegistryError(f"poster registry validation failed: {exc}") from exc
    for warning in poster_warnings:
        print(f"warning: {warning}", file=sys.stderr)
    out: OrderedDict[str, bytes] = OrderedDict()
    streamed = [r for r in rows if r["stream"]["transport"] == "streamhost"]
    production = [r for r in rows if r["lifecycle"] == "production"]

    def emit_invocation(row: dict[str, Any]) -> str:
        # No --encoder-preset: the daemon default (ultrafast) governs the whole
        # fleet. A per-tile value here was 36 restatements of the default and one
        # silent divergence (irix on veryfast, with no recorded reason).
        return row["render"]["tilesManifestInvocation"].rstrip("\n") + "\n"

    emits = "".join(
        r["render"].get("tilesManifestPrelude", "") + emit_invocation(r)
        for r in sorted(production, key=lambda x: x["render"]["tilesManifestOrder"])
    )
    out["streamhost/tiles-manifest.sh"] = apply_count_tokens(
        template("tiles-manifest.sh.in", "@@TILE_EMITS@@", emits.rstrip("\n")), rows
    )

    groups: dict[int, list[str]] = {}
    for row in sorted(production, key=lambda x: x["runtime"]["bringUpOrder"]):
        groups.setdefault(row["render"]["bringUpGroup"], []).append(row["tileDir"])
    bring = "TILES=(\n" + "".join("  " + " ".join(groups[g]) + "\n" for g in sorted(groups)) + ")"
    out["streamhost/bring-up-all.sh"] = apply_count_tokens(
        template("bring-up-all.sh.in", "@@BRING_UP_TILES@@", bring), rows
    )

    build_rows = [item for row in rows for item in row.get("build", {}).get("rows", [])]
    build_rows += globals_doc.get("sharedBuildRows", [])
    build_rows.sort(key=lambda item: item["order"])
    manifest = "".join(item.get("prelude", "") + item["line"] for item in build_rows).rstrip("\n")
    default: dict[int, list[tuple[int, str]]] = {}
    for item in build_rows:
        if "defaultOrder" in item:
            d = item["defaultOrder"]
            default.setdefault(d["group"], []).append((d["position"], item["value"]["key"]))
    default_lines = []
    for group in sorted(default):
        keys = " ".join(key for _, key in sorted(default[group]))
        default_lines.append(("DEFAULT_ORDER=(" if group == min(default) else "  ") + keys)
    default_lines[-1] += ")"
    build_template = (TEMPLATES / "build-all.sh.in").read_text()
    build_template = build_template.replace("@@BUILD_MANIFEST@@", manifest).replace(
        "@@BUILD_DEFAULT_ORDER@@", "\n".join(default_lines)
    )
    out["scripts/build-guests/build-all.sh"] = build_template.encode()

    signal = OrderedDict()
    for row in sorted(streamed, key=lambda x: x["render"]["signalOrder"]):
        signal[row["id"]] = {
            "udpPort": row["stream"]["udpPort"],
            "hashFile": f"/data/vms/streamhost/tiles/{row['tileDir']}/cert_hash_b64.txt",
        }
    out["scripts/serve/tiles.json"] = (json.dumps(signal, indent=2, ensure_ascii=False) + "\n").encode()
    out["scripts/serve/webroot/gallery-manifest.json"] = emit_gallery_manifest(rows)

    golden = OrderedDict(
        [
            ("_generated", "scripts/tiles-registry.py generate; DO NOT EDIT; run `make tile-registry-generate`"),
            ("_comment", globals_doc["goldenComment"]),
            ("tiles", OrderedDict()),
        ]
    )
    for row in sorted(production, key=lambda x: x["render"]["goldenOrder"]):
        reset = OrderedDict(row["reset"])
        if reset.get("resetMode") == "pve-rollback":
            reset["pveVmid"] = row["runtime"]["pve"]["vmid"]
        golden["tiles"][row["id"]] = reset
    out["scripts/serve/golden-manifest.json"] = (json.dumps(golden, indent=1, ensure_ascii=False) + "\n").encode()

    action = OrderedDict(
        [
            ("_generated", "scripts/tiles-registry.py generate; DO NOT EDIT; run `make tile-registry-generate`"),
            ("_README", globals_doc["actionMapReadme"]),
            ("_default", globals_doc["actionMapDefault"]),
        ]
    )
    action_rows = [r for r in rows if "actionMap" in r.get("operator", {})]
    for row in sorted(action_rows, key=lambda x: x["render"]["actionMapOrder"]):
        item = row["operator"]["actionMap"]
        action[item["key"]] = item["value"]
    out["scripts/tools/gallery-action-map.json"] = (json.dumps(action, indent=2, ensure_ascii=True) + "\n").encode()

    binding_rows = [r for r in rows if r.get("enabled") and "bindingLine" in r["render"]]
    bindings = "".join(
        r["render"].get("bindingPrelude", "") + r["render"]["bindingLine"]
        for r in sorted(binding_rows, key=lambda x: x["render"]["bindingOrder"])
    )
    out["spa/src/three/archetypeRegistry.ts"] = apply_count_tokens(
        template("archetypeRegistry.ts.in", "@@OS_BINDINGS@@", bindings.rstrip("\n")), rows
    )
    out["spa/src/mock/manifest.json"] = render_mock(rows)

    museum_rows = [r for r in rows if "museumBlock" in r["render"]]
    museum = "".join(
        r["render"].get("museumPrelude", "") + r["render"]["museumBlock"]
        for r in sorted(museum_rows, key=lambda x: x["render"]["museumOrder"])
    )
    out["spa/src/data/museumCatalog.ts"] = apply_count_tokens(
        template("museumCatalog.ts.in", "@@MUSEUM_ENTRIES@@", museum.rstrip("\n")), rows
    )
    out["spa/src/data/posters.ts"] = render_posters(posters)
    out["spa/src/data/demoPrograms.ts"] = render_demo_programs(rows)
    out["spa/src/data/keyboards.ts"] = render_keyboards(rows)
    catalog_rows = [r for r in rows if "catalogBlock" in r["render"]]
    catalog = "".join(
        r["render"].get("catalogPrelude", "") + r["render"]["catalogBlock"]
        for r in sorted(catalog_rows, key=lambda x: x["render"]["catalogOrder"])
    )
    out["spa/src/data/catalog.ts"] = template("catalog.ts.in", "@@CATALOG_ENTRIES@@", catalog.rstrip("\n"))

    public_rows = []
    for row in sorted(rows, key=lambda x: x["id"]):
        clean = OrderedDict((k, v) for k, v in row.items() if k not in {"_path", "render"})
        public_rows.append(clean)
    index = OrderedDict(
        [
            ("_generated", "scripts/tiles-registry.py generate; DO NOT EDIT"),
            ("schemaVersion", 1),
            ("tiles", public_rows),
        ]
    )
    out["registry/index.json"] = (json.dumps(index, indent=2, ensure_ascii=False) + "\n").encode()

    declarations = OrderedDict(
        [
            ("_generated_by", "scripts/tiles-registry.py"),
            ("_schema", "declared tile capabilities; labctl gen adds observed state"),
            ("tiles", OrderedDict()),
        ]
    )
    for row in sorted(streamed, key=lambda x: x["tileDir"]):
        labctl = row.get("operator", {}).get("labctl", {})
        declarations["tiles"][row["tileDir"]] = OrderedDict((k, labctl.get(k)) for k in LABCTL_KEYS)
    out["registry/generated/labctl-declarations.json"] = (
        json.dumps(declarations, indent=2, ensure_ascii=False) + "\n"
    ).encode()
    return out


def _parse_drift_gate_paths() -> list[str]:
    text = (REPO / "scripts/check-generated-drift.sh").read_text()
    match = re.search(r"GENERATED_PATHS=\(\n(.*?)\n\)", text, re.DOTALL)
    if not match:
        raise RegistryError("cannot locate GENERATED_PATHS in check-generated-drift.sh")
    return [line.strip() for line in match.group(1).splitlines() if line.strip() and not line.strip().startswith("#")]


def _parse_file_size_gate() -> tuple[set[str], list[str]]:
    text = (REPO / "scripts/check-file-size.mjs").read_text()
    gen = re.search(r"const GENERATED = new Set\(\[(.*?)\]\)", text, re.DOTALL)
    pre = re.search(r"const GENERATED_PREFIXES = \[(.*?)\]", text, re.DOTALL)
    if not gen or not pre:
        raise RegistryError("cannot locate GENERATED/GENERATED_PREFIXES in check-file-size.mjs")
    files = set(re.findall(r'"([^"]+)"', gen.group(1)))
    prefixes = re.findall(r'"([^"]+)"', pre.group(1))
    return files, prefixes


def _parse_shell_sources_excludes() -> set[str]:
    text = (REPO / "scripts/lint/shell-sources.sh").read_text()
    return set(re.findall(r":\(exclude\)(\S+\.sh)", text))


def check_gate_lists(output_keys: list[str]) -> list[str]:
    """Assert the hand-mirrored generated-path gate lists still match generated()."""
    keys = set(output_keys)
    mismatches: list[str] = []

    drift = set(_parse_drift_gate_paths())
    if drift != keys:
        mismatches.append(
            f"check-generated-drift.sh GENERATED_PATHS drift: only-in-gate={sorted(drift - keys)} "
            f"only-in-generator={sorted(keys - drift)}"
        )

    size_files, size_prefixes = _parse_file_size_gate()
    stale = sorted(size_files - keys)
    if stale:
        mismatches.append(f"check-file-size.mjs GENERATED has stale entries: {stale}")
    uncovered = sorted(k for k in keys if k not in size_files and not any(k.startswith(p) for p in size_prefixes))
    if uncovered:
        mismatches.append(f"check-file-size.mjs GENERATED misses generated outputs: {uncovered}")

    excludes = _parse_shell_sources_excludes()
    if excludes != set(GENERATED_SHELL):
        mismatches.append(
            f"shell-sources.sh excludes drift: gate={sorted(excludes)} expected={sorted(GENERATED_SHELL)}"
        )
    if not set(GENERATED_SHELL) <= keys:
        mismatches.append(f"GENERATED_SHELL not a subset of generated outputs: {sorted(set(GENERATED_SHELL) - keys)}")

    # The edge's DNAT range lives in three places that must agree, and when they
    # drift nothing on the box notices: the tile is active, its ticket is
    # accepted, signalling is valid, and the daemon simply never sees a session.
    # registry-v1.json is the source of truth; assert the installer matches it.
    relay = json.loads((REGISTRY / "registry-v1.json").read_text())["ports"]
    want = f'RELAY_RANGE_DEFAULT="{relay["publicRelayLow"]}-{relay["publicRelayHigh"]}"'
    installer = REPO / "scripts/serve/install-public-relay.sh"
    if installer.is_file() and want not in installer.read_text(encoding="utf-8"):
        mismatches.append(
            f"install-public-relay.sh does not carry {want} — the edge installer and "
            f"registry-v1.json ports.publicRelay* must agree, or tiles ship unreachable"
        )

    if mismatches:
        raise RegistryError("generated-path gate lists out of sync:\n  - " + "\n  - ".join(mismatches))
    return [
        f"GATE-LISTS-IN-SYNC ({len(keys)} generated paths across 3 gate configs)",
        f"PUBLIC-RELAY-RANGE-IN-SYNC ({relay['publicRelayLow']}-{relay['publicRelayHigh']}"
        " in registry-v1.json == install-public-relay.sh)",
    ]


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        mode = path.stat().st_mode if path.exists() else 0o100644
        os.chmod(tmp, mode & 0o777)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def scaffold_template(name: str, values: dict[str, str]) -> bytes:
    text = (TEMPLATES / name).read_text()
    for key, value in values.items():
        text = text.replace(f"@@{key}@@", value)
    leftovers = sorted(set(re.findall(r"@@[A-Z0-9_]+@@", text)))
    if leftovers:
        raise RegistryError(f"unfilled scaffold placeholders in {name}: {', '.join(leftovers)}")
    return text.encode()


def cmd_new(os_id: str, tier: int, archetype: str, slot_arg: str) -> int:
    """Create an inert candidate scaffold, then regenerate canonical outputs."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", os_id):
        raise RegistryError("new id must match [a-z0-9][a-z0-9-]*")
    globals_doc, rows = load()
    if any(row["id"] == os_id for row in rows):
        raise RegistryError(f"tile {os_id!r} already exists")

    archetypes = {row.get("spa", {}).get("archetypeId") for row in rows}
    if archetype not in archetypes:
        raise RegistryError(f"unknown archetype {archetype!r}; choose one of {sorted(archetypes)}")

    used_slots = {row.get("stream", {}).get("slot") for row in rows}
    used_slots.discard(None)
    if slot_arg == "auto":
        slot = next(value for value in range(NEW_TILE_SLOT_FLOOR, 11536) if value not in used_slots)
    else:
        try:
            slot = int(slot_arg)
        except ValueError as exc:
            raise RegistryError("--slot must be 'auto' or a non-negative integer") from exc
        if slot < 0 or slot > 11535:
            raise RegistryError("--slot must keep 54000+slot within the UDP port range")
        if slot in used_slots:
            owner = next(row["id"] for row in rows if row.get("stream", {}).get("slot") == slot)
            raise RegistryError(f"slot {slot} is already reserved by {owner}")
    udp_port = globals_doc["ports"]["productionBase"] + slot
    if any(row.get("stream", {}).get("udpPort") == udp_port for row in rows):
        raise RegistryError(f"UDP port {udp_port} is already in use")

    tier_defaults = {
        1: ("fast", "~2-5m", "full"),
        2: ("installed", "~15-30m", "partial"),
        3: ("graphical", "~30-90m", "vision"),
    }
    build_class, estimated, automation = tier_defaults[tier]
    build_order = (
        max(
            (item["order"] for row in rows for item in row.get("build", {}).get("rows", [])),
            default=0,
        )
        + 1
    )
    output_dir = "".join(part.capitalize() for part in os_id.split("-"))
    line_value = OrderedDict(
        [
            ("key", os_id),
            ("script", f"{os_id}.sh"),
            ("outputDir", output_dir),
            ("class", build_class),
            ("estimated", estimated),
            ("automation", automation),
            ("produces", "TODO"),
            ("flags", []),
        ]
    )
    rendered_line = (
        f'  "{os_id:<12}|{"tiles/" + os_id + ".sh":<30}|{output_dir:<14}|{build_class:<9}|{estimated:<8}|{automation:<8}|TODO"\n'
    )
    row = OrderedDict(
        [
            ("schemaVersion", 1),
            ("id", os_id),
            ("era_year", date.today().year),
            ("tileDir", os_id),
            ("lifecycle", "candidate"),
            ("enabled", False),
            ("build", {"rows": [{"order": build_order, "prelude": "", "line": rendered_line, "value": line_value}]}),
            ("operator", {}),
            ("render", {}),
            # A disabled candidate reserves identity/slot/port without entering any
            # generated runtime surface. Promotion changes transport to streamhost and
            # fills runtime/reset/render after the builder and golden are proven.
            ("stream", {"transport": "showcase", "udpPort": udp_port, "slot": slot}),
            ("guestDoc", f"docs/guests/{os_id}.md"),
            ("credentialsRef", f"guest/{os_id}"),
            (
                "spa",
                {
                    "archetypeId": archetype,
                    "transport": "showcase",
                    "accentColor": "#64748b",
                    "eraLabel": f"TBD · {os_id}",
                },
            ),
            (
                "museum",
                {
                    "id": os_id,
                    "displayName": os_id,
                    "year": date.today().year,
                    "lineage": "TODO",
                    "arch": "TODO",
                    "accent": "#64748b",
                },
            ),
            (
                "notes",
                [
                    f"new-os Tier {tier} scaffold; reserved slot {slot}/UDP {udp_port}",
                    "disabled candidate: not part of streamhost, signal, reset, or SPA lineups",
                ],
            ),
        ]
    )

    registry_path = TILES / f"{os_id}.json"
    builder_path = REPO / "scripts/build-guests/tiles" / f"{os_id}.sh"
    guest_path = REPO / "docs/guests" / f"{os_id}.md"
    coldboot_path = REPO / "scripts/coldboot" / f"{os_id}-bootrec-arm.sh"
    for path in (registry_path, builder_path, guest_path, coldboot_path):
        if path.exists():
            raise RegistryError(f"refusing to overwrite existing {path.relative_to(REPO)}")

    values = {
        "OS_ID": os_id,
        "TILE_DIR": os_id,
        "TIER": str(tier),
        "SLOT": str(slot),
        "UDP_PORT": str(udp_port),
        "ARCHETYPE": archetype,
    }
    scaffold_files = OrderedDict(
        [
            (registry_path, (json.dumps(row, indent=2, ensure_ascii=False) + "\n").encode()),
            (builder_path, scaffold_template(f"new-os-builder-tier{tier}.sh.in", values)),
            (guest_path, scaffold_template("new-os-guest.md.in", values)),
            (coldboot_path, scaffold_template("new-os-coldboot-arm.sh.in", values)),
        ]
    )
    try:
        for path, data in scaffold_files.items():
            atomic_write(path, data)
        os.chmod(builder_path, 0o755)
        # A scaffold is an ordinary canonical registry change: leave generated
        # files current so `make tile-registry-check` passes immediately.
        cmd_generate()
    except Exception:
        for path in scaffold_files:
            path.unlink(missing_ok=True)
        raise
    print(f"scaffolded {os_id}: tier={tier} archetype={archetype} slot={slot} udp={udp_port}")
    print(f"  registry/tiles/{os_id}.json")
    print(f"  scripts/build-guests/tiles/{os_id}.sh")
    print(f"  docs/guests/{os_id}.md")
    print(f"  scripts/coldboot/{os_id}-bootrec-arm.sh")
    print("candidate is disabled; fill TODOs and prove its golden before promotion")
    return 0


def cmd_generate() -> int:
    outputs = generated()
    for rel, data in outputs.items():
        atomic_write(REPO / rel, data)
        print(f"generated {rel}")
    return 0


def compare_live_labctl(outputs: OrderedDict[str, bytes]) -> list[str]:
    live = Path("/data/vms/streamhost/tiles.json")
    if not live.exists():
        return ["SKIP live labctl semantic check (/data/vms/streamhost/tiles.json absent)"]
    current = json.loads(live.read_text()).get("tiles", {})
    declared = json.loads(outputs["registry/generated/labctl-declarations.json"])["tiles"]
    mismatches = []
    if set(current) != set(declared):
        mismatches.append(f"tile set current={sorted(current)} declared={sorted(declared)}")
    for tile in sorted(set(current) & set(declared)):
        for key in LABCTL_KEYS:
            actual = current[tile].get(key)
            if key == "notes" and isinstance(actual, str):
                actual = re.sub(
                    r"; (?:no 'golden' snapshot found:.*|golden snapshot state unknown \(probe failed\))$",
                    "",
                    actual,
                )
            if actual != declared[tile].get(key):
                mismatches.append(
                    f"{tile}.{key}: current={current[tile].get(key)!r} declared={declared[tile].get(key)!r}"
                )
    if mismatches:
        raise RegistryError("live labctl declared-field mismatch:\n  - " + "\n  - ".join(mismatches))
    return [
        f"SEMANTIC-IDENTICAL live labctl declarations ({len(declared)} tiles; "
        "observed golden state intentionally excluded)"
    ]


def cmd_check() -> int:
    outputs = generated()
    bad = False
    for rel, expected in outputs.items():
        path = REPO / rel
        actual = path.read_bytes() if path.exists() else b""
        if actual == expected:
            print(f"BYTE-IDENTICAL {rel}")
            continue
        bad = True
        print(f"DRIFT {rel}", file=sys.stderr)
        try:
            a = actual.decode().splitlines(keepends=True)
            b = expected.decode().splitlines(keepends=True)
            sys.stderr.writelines(difflib.unified_diff(a, b, fromfile=rel, tofile=f"generated/{rel}"))
        except UnicodeDecodeError:
            print("  binary content differs", file=sys.stderr)
    for line in check_gate_lists(list(outputs)):
        print(line)
    for line in compare_live_labctl(outputs):
        print(line)
    _, rows = load()
    hand_managed = []
    for row in sorted(
        (r for r in rows if r.get("stream", {}).get("transport") == "streamhost"),
        key=lambda r: (r.get("lifecycle") != "production", r["id"]),
    ):
        if is_x11_runtime(row):
            print(f"LAUNCHER-X11-RUNTIME {row['id']}: tracked x11-runtime.sh (Xvfb+MAME, no QEMU launcher)")
            continue
        parity = row["runtime"]["qemu"]["launcherParity"]
        label = parity["status"].upper()
        print(f"LAUNCHER-{label} {row['id']}: {parity['reason']}")
        if parity["status"] == "hand-managed":
            hand_managed.append(row["id"])
    if hand_managed:
        print("HAND-MANAGED launcher cutover exclusions: " + ", ".join(hand_managed))
    return 1 if bad else 0


def cmd_paths() -> int:
    """Print the authoritative list of generated output paths (one per line)."""
    for rel in generated():
        print(rel)
    return 0


def cmd_explain(os_id: str) -> int:
    _, rows = validate()
    row = next((item for item in rows if item["id"] == os_id), None)
    if row is None:
        raise RegistryError(f"unknown tile {os_id!r}")
    summary = OrderedDict(
        [
            ("registry", str(row["_path"].relative_to(REPO))),
            ("lifecycle", row["lifecycle"]),
            ("tileDir", row.get("tileDir")),
            (
                "signal",
                {
                    "udpPort": row.get("stream", {}).get("udpPort"),
                    "hashFile": f"/data/vms/streamhost/tiles/{row.get('tileDir')}/cert_hash_b64.txt"
                    if row.get("tileDir")
                    else None,
                },
            ),
            ("emitArgs", row.get("runtime", {}).get("qemu", {}).get("emitArgs")),
            ("bringUpOrder", row.get("runtime", {}).get("bringUpOrder")),
            ("reset", row.get("reset")),
            ("labctl", row.get("operator", {}).get("labctl")),
            ("spa", row.get("spa")),
            ("museum", row.get("museum")),
            ("build", [item["value"] for item in row.get("build", {}).get("rows", [])]),
        ]
    )
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="alias for the check command")
    sub = ap.add_subparsers(dest="command")
    sub.add_parser("validate")
    sub.add_parser("generate")
    sub.add_parser("check")
    sub.add_parser("count")
    sub.add_parser("paths")
    explain = sub.add_parser("explain")
    explain.add_argument("id")
    new = sub.add_parser("new", help="scaffold an inert candidate tile")
    new.add_argument("id")
    new.add_argument("--tier", type=int, choices=(1, 2, 3), required=True)
    new.add_argument("--archetype", required=True)
    new.add_argument("--slot", required=True, help="auto or an explicit non-negative slot")
    ns = ap.parse_args()
    try:
        command = "check" if ns.check else ns.command
        if command in {"validate", "count"}:
            _, rows = validate()
            counts = {
                kind: sum(r.get("lifecycle") == kind for r in rows)
                for kind in ("production", "experiment", "showcase", "candidate")
            }
            if command == "count":
                production_streamed = sum(
                    r["lifecycle"] == "production" and r["stream"]["transport"] == "streamhost" for r in rows
                )
                print(
                    f"{len(rows)} lineup entries: {production_streamed} streamhost production tiles, "
                    f"{counts['showcase']} showcase posters"
                )
            else:
                print(
                    f"VALID registry: {len(rows)} entries "
                    f"({counts['production']} production, {counts['experiment']} experiment, "
                    f"{counts['showcase']} showcase, {counts['candidate']} candidate)"
                )
            return 0
        if command == "generate":
            return cmd_generate()
        if command == "check":
            return cmd_check()
        if command == "paths":
            return cmd_paths()
        if command == "explain":
            return cmd_explain(ns.id)
        if command == "new":
            return cmd_new(ns.id, ns.tier, ns.archetype, ns.slot)
        ap.print_help()
        return 2
    except (RegistryError, OSError, ValueError, SyntaxError) as exc:
        print(f"tile-registry: ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
