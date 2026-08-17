"""Registry schema validation: the JSON-Schema-lite evaluator and the tile-v1 shape check."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from .constants import REPO
from .loading import is_x11_runtime


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
            for key in ("stationDir", "udpPort", "fps", "audio", "touch", "pointer"):
                container = row if key == "stationDir" else stream
                if key not in container:
                    fail(errors, row, f"streamhost entry missing {key}")
            if stream.get("pointer", {}).get("transport") not in pointers:
                fail(errors, row, "invalid pointer transport")
            runtime = row.get("runtime", {})
            # x11 stations are the non-QEMU streamhost runtime (issue #20 / IRIX):
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
