"""Renderers for the RENDERED (never-committed) runtime documents: gallery-manifest,
poster-docs, tiles.json, golden-manifest, index.json, and their shared template
helpers (also reused by generate.py for the committed artifacts)."""

from __future__ import annotations

import json
import re
import sys
from collections import OrderedDict
from typing import Any

from poster_registry import PosterError, load_posters

from .constants import POSTERS, TEMPLATES
from .loading import RegistryError, is_x11_runtime
from .validate_rules import is_hidden, validate


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


def ts_scalar(value: Any) -> str:
    """Render a flat registry value as a TypeScript literal (single-quoted strings)."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"
    return str(value)


def render_binding_line(row: dict[str, Any], id_width: int) -> str:
    """One OS_BINDINGS row, derived from the typed spa fields."""
    parts = [f"osId: {ts_scalar(row['id'])}"]
    parts += [f"{key}: {ts_scalar(value)}" for key, value in row["spa"].items()]
    comment = row["render"].get("bindingComment")
    suffix = f" // {comment}" if comment else ""
    label = f"{row['id']}:"
    return f"  {label:<{id_width}}{{ {', '.join(parts)} }},{suffix}\n"


SHELL_BARE_TOKEN = re.compile(r"[A-Za-z0-9@%_+=:,./-]+")


def shell_token(token: str) -> str:
    """Quote an emit argument for stations-manifest.sh; $ stays live for $T expansion."""
    if SHELL_BARE_TOKEN.fullmatch(token):
        return token
    return '"' + token.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_emit_invocation(row: dict[str, Any]) -> str:
    """The stations-manifest.sh emit line, derived from the typed runtime emitArgs."""
    runtime = row.get("runtime", {})
    source = runtime.get("x11", {}) if is_x11_runtime(row) else runtime.get("qemu", {})
    words = [shell_token(str(arg)) for arg in source.get("emitArgs", [])]
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = f"{current} {word}" if current else word
        if current and len(candidate) > 74:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return f"emit {row['stationDir']} \\\n  " + " \\\n  ".join(lines) + "\n"


BUILD_COLUMNS = ("key", "script", "outputDir", "class", "estimated", "automation")


def build_line_widths(items: list[dict[str, Any]]) -> list[int]:
    widths = [0] * len(BUILD_COLUMNS)
    for item in items:
        for i, column in enumerate(BUILD_COLUMNS):
            widths[i] = max(widths[i], len(item["value"][column]) + 1)
    return widths


def render_build_line(item: dict[str, Any], widths: list[int]) -> str:
    """One build-all.sh manifest row, derived from the typed build fields."""
    value = item["value"]
    padded = "|".join(f"{value[column]:<{width}}" for column, width in zip(BUILD_COLUMNS, widths))
    tail = "|".join([value["produces"], *value["flags"]])
    return f'  "{padded}|{tail}"\n'


def render_poster_index(posters: OrderedDict[str, dict[str, Any]]) -> bytes:
    """The eager, bundle-side poster surface: existence + hero path only.

    The full prose lives in poster-docs.json, fetched at runtime, so poster
    copy edits reach the gallery without an SPA rebuild.
    """
    index = OrderedDict((os_id, ({"hero": doc["hero"]} if "hero" in doc else {})) for os_id, doc in posters.items())
    encoded = json.dumps(index, indent=2, ensure_ascii=False)
    return (
        "// DO NOT EDIT — generated by scripts/stations-registry.py generate from\n"
        "// registry/posters/*.md; run `make station-registry-generate`.\n"
        "// Existence + hero only — the prose is runtime data (/poster-docs.json).\n\n"
        f"const POSTER_INDEX = {encoded} as const satisfies Record<string, {{ hero?: string }}>;\n\n"
        "export function posterFor(osId: string): { hero?: string } | undefined {\n"
        "  return POSTER_INDEX[osId as keyof typeof POSTER_INDEX];\n"
        "}\n"
    ).encode()


def render_poster_docs(posters: OrderedDict[str, dict[str, Any]]) -> bytes:
    document = OrderedDict(
        [
            ("_generated", "scripts/stations-registry.py generate; PUBLIC DATA ONLY; DO NOT EDIT"),
            ("posters", posters),
        ]
    )
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode()


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
        "// DO NOT EDIT — generated by scripts/stations-registry.py generate from\n"
        "// registry/stations/*.json (keyboard); run `make station-registry-generate`.\n"
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
        "// DO NOT EDIT — generated by scripts/stations-registry.py generate from\n"
        "// registry/stations/*.json (demoProgram); run `make station-registry-generate`.\n"
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
        # Soft hide (registry `listing`). The ROW STAYS — dropping it is what a
        # deployment-only override used to do, and it is exactly what breaks the
        # /os/<id> deep link, since the UI resolves that id out of this manifest.
        # Emitted only when hidden, so every listed station's JSON is byte-unchanged.
        # The reason/since stay in registry/index.json: this document is public,
        # served to every browser, and the UI renders none of that prose.
        if is_hidden(row):
            entry["listed"] = False
        for key in ("ramMB", "ramKB", "notes", "era", "eraSoftware", "periodBrowser", "iconicApps", "blurb"):
            if key in museum:
                entry[key] = museum[key]
        for key in ("endpoint", "pointerRel", "hardwareInput", "coldBoot", "bootVideo"):
            if key in spa:
                entry[key] = spa[key]
        # Grid badge: a machine a visitor will TRY to point at, whose pointer is
        # only relative. Derived from stream.pointer (the truth about the guest),
        # NOT from spa.pointerRel — that flag is the UI's input-MODEL hint and
        # three relative stations legitimately lack it, so keying the badge off it
        # would quietly under-report.
        pointer = row.get("stream", {}).get("pointer", {})
        if pointer.get("present") and not pointer.get("absolute"):
            entry["relativePointerOnly"] = True
        entries.append(entry)

    document = OrderedDict(
        [
            ("_generated", "scripts/stations-registry.py generate; PUBLIC DATA ONLY; DO NOT EDIT"),
            ("schemaVersion", 1),
            ("entries", entries),
        ]
    )
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode()


def emit_registry_index(rows: list[dict[str, Any]]) -> bytes:
    """Emit the whole-registry aggregate: every entry, minus generator-only data."""
    public_rows = []
    for row in sorted(rows, key=lambda x: x["id"]):
        clean = OrderedDict((k, v) for k, v in row.items() if not str(k).startswith("_") and k != "render")
        public_rows.append(clean)
    index = OrderedDict(
        [
            ("_generated", "scripts/stations-registry.py render; DO NOT EDIT"),
            ("schemaVersion", 1),
            ("tiles", public_rows),
        ]
    )
    return (json.dumps(index, indent=2, ensure_ascii=False) + "\n").encode()


def rendered() -> OrderedDict[str, bytes]:
    """The RENDERED artifacts: resolved on demand, never committed.

    Every one is a pure restatement of the registry with no hand-written byte of
    its own, and every one of their consumers can ASK for them: the publish path
    pipes them at the box, the SPA fetches them at runtime, the tests render into
    memory, the Vite dev server answers a request by rendering. Committing them
    meant a gallery string had four search hits with no way to tell master from
    copy, and ~1.2 MB of regenerated JSON in the diff of every station edit.

    `render` writes them to RENDER_DIR (gitignored), `emit <name>` streams one to
    stdout, `paths --rendered` lists them. Nothing checks them for drift because
    nothing can drift: there is no second copy.

    The one generated JSON deliberately left OUT of this set is
    registry/generated/labctl-declarations.json — the box's gen_tiles_json.py
    opens it as a file, so it must exist without a generator run.
    """
    globals_doc, rows = validate()
    try:
        posters, poster_warnings = load_posters(POSTERS, {row["id"] for row in rows})
    except (OSError, PosterError) as exc:
        raise RegistryError(f"poster registry validation failed: {exc}") from exc
    for warning in poster_warnings:
        print(f"warning: {warning}", file=sys.stderr)
    streamed = [r for r in rows if r["stream"]["transport"] == "streamhost"]
    production = [r for r in rows if r["lifecycle"] == "production"]
    out: OrderedDict[str, bytes] = OrderedDict()

    out["gallery-manifest.json"] = emit_gallery_manifest(rows)
    out["poster-docs.json"] = render_poster_docs(posters)

    signal = OrderedDict()
    for row in sorted(streamed, key=lambda x: x["render"]["signalOrder"]):
        signal[row["id"]] = {
            "udpPort": row["stream"]["udpPort"],
            "hashFile": f"/data/vms/streamhost/stations/{row['stationDir']}/cert_hash_b64.txt",
        }
    out["tiles.json"] = (json.dumps(signal, indent=2, ensure_ascii=False) + "\n").encode()

    golden = OrderedDict(
        [
            ("_generated", "scripts/stations-registry.py render; DO NOT EDIT"),
            ("_comment", globals_doc["goldenComment"]),
            ("tiles", OrderedDict()),
        ]
    )
    for row in sorted(production, key=lambda x: x["render"]["goldenOrder"]):
        reset = OrderedDict(row["reset"])
        if reset.get("resetMode") == "pve-rollback":
            reset["pveVmid"] = row["runtime"]["pve"]["vmid"]
        golden["tiles"][row["id"]] = reset
    out["golden-manifest.json"] = (json.dumps(golden, indent=1, ensure_ascii=False) + "\n").encode()

    action = OrderedDict(
        [
            ("_generated", "scripts/stations-registry.py render; DO NOT EDIT"),
            ("_README", globals_doc["actionMapReadme"]),
            ("_default", globals_doc["actionMapDefault"]),
        ]
    )
    action_rows = [r for r in rows if "actionMap" in r.get("operator", {})]
    for row in sorted(action_rows, key=lambda x: x["render"]["actionMapOrder"]):
        item = row["operator"]["actionMap"]
        action[item["key"]] = item["value"]
    out["gallery-action-map.json"] = (json.dumps(action, indent=2, ensure_ascii=True) + "\n").encode()

    out["mock-manifest.json"] = render_mock(rows)
    out["index.json"] = emit_registry_index(rows)
    return out
