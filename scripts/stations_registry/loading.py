"""Registry loading and the tolerant TypeScript-object mini-parser."""

from __future__ import annotations

import ast
import json
import re
from collections import OrderedDict
from pathlib import Path
from typing import Any

from .constants import ICQ_ROSTER, REGISTRY, REPO, TILES


class RegistryError(Exception):
    pass


def is_x11_runtime(row: dict[str, Any]) -> bool:
    """True for the non-QEMU x11 streamhost runtime (SH_CAPTURE=x11 tiles).

    Discriminated by a runtime.x11 block; the stationEnv carries the matching
    SH_STATION_RUNTIME=x11 marker the service dispatch keys on. The block is still
    called `x11` because that names the RUNTIME (an emulator managed by
    x11-runtime.sh rather than a QEMU VM). Its FRAME SOURCE is chosen separately
    by runtime.x11.capture and may be `shm`, in which case no X server is
    involved at all.
    """
    return "x11" in row.get("runtime", {})


def icq_roster() -> dict[str, dict[str, Any]]:
    """The retronet ICQ personas, keyed by station id.

    scripts/retronet/icq/roster.json is the SINGLE source for uin/nick/client/
    onboarded (the contact seeder reads the same file); the registry never
    restates them. Returns {} when the roster is absent so a checkout without
    the retronet tree still renders.
    """
    if not ICQ_ROSTER.is_file():
        return {}
    try:
        doc = json.loads(ICQ_ROSTER.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise RegistryError(f"cannot load {ICQ_ROSTER}: {exc}") from exc
    return {row["station"]: row for row in doc.get("stations", [])}


def fixture_path(row: dict[str, Any]) -> Path | None:
    """The tile's --env-append-file: the hand-written source of its append env keys."""
    runtime = row.get("runtime", {})
    source = runtime.get("x11") if is_x11_runtime(row) else runtime.get("qemu", {})
    args = source.get("emitArgs", [])
    if "--env-append-file" in args:
        raw = args[args.index("--env-append-file") + 1]
        return REPO / raw.replace("$T", "streamhost/stations")
    return None


def parse_env_fixture(path: Path) -> OrderedDict[str, str]:
    env: OrderedDict[str, str] = OrderedDict()
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        env[key.strip()] = value
    return env


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
        # The station.env.fixture owns its keys; the registry entry owns the
        # emitter-written keys. Everything downstream (validators, index.json)
        # sees the merged view — the same env the emitter's append produces.
        fixture = fixture_path(row)
        if fixture is not None and fixture.is_file():
            fixture_env = parse_env_fixture(fixture)
            row["_fixtureEnv"] = fixture_env
            runtime = row.setdefault("runtime", OrderedDict())
            recorded = runtime.get("stationEnv", OrderedDict())
            row["_recordedTileEnv"] = recorded
            merged = OrderedDict(recorded)
            merged.update(fixture_env)
            runtime["stationEnv"] = merged
        rows.append(row)
    if not rows:
        raise RegistryError("registry/stations contains no entries")
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
