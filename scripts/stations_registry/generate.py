"""Generation of the COMMITTED artifacts (stations-manifest.sh, build-all.sh,
archetypeRegistry.ts, keyboards.ts, labctl-declarations.json, ...), the gate-list
drift meta-check, and the `new` scaffolder."""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from collections import OrderedDict
from pathlib import Path

from poster_registry import PosterError, load_posters
from serve.walkin.naming import SLOT_MAX as WALKIN_SLOT_MAX
from serve.walkin.naming import SLOT_MIN as WALKIN_SLOT_MIN

from .constants import GENERATED_SHELL, LABCTL_KEYS, POSTERS, REGISTRY, REPO, TEMPLATES
from .loading import RegistryError
from .render import (
    apply_count_tokens,
    build_line_widths,
    render_binding_line,
    render_build_line,
    render_demo_programs,
    render_emit_invocation,
    render_keyboards,
    render_poster_index,
    template,
)
from .validate_rules import validate


def slot_refusal(globals_doc: dict, value: int) -> str | None:
    """Why slot `value` cannot host a production station, or None if it can.

    `--slot auto` used to know only which slots were already taken, so it walked
    straight into the walk-in clone pool's reservation and then past the edge's
    relay window. Both were invisible until promotion failed, which is why this
    refuses at scaffold time for an explicit --slot too.
    """
    if WALKIN_SLOT_MIN <= value <= WALKIN_SLOT_MAX:
        return (
            f"slots {WALKIN_SLOT_MIN}-{WALKIN_SLOT_MAX} are reserved for the walk-in "
            "clone pool (scripts/serve/walkin/naming.py)"
        )
    ports = globals_doc["ports"]
    relay_low = ports.get("publicRelayLow")
    relay_high = ports.get("publicRelayHigh")
    if relay_low is not None and relay_high is not None:
        port = ports["productionBase"] + value
        if not relay_low <= port <= relay_high:
            return (
                f"UDP {port} is outside the public relay window {relay_low}-{relay_high} "
                "(ports.publicRelay* in registry/registry-v1.json), so the station would "
                "stream on the LAN while being unreachable through the edge"
            )
    return None


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

    # No --encoder-preset in emitArgs: the daemon default (ultrafast) governs the
    # whole fleet. A per-station value here was 36 restatements of the default and
    # one silent divergence (irix on veryfast, with no recorded reason).
    emits = "".join(
        r["render"].get("stationsManifestPrelude", "") + render_emit_invocation(r)
        for r in sorted(production, key=lambda x: x["render"]["stationsManifestOrder"])
    )
    out["streamhost/stations-manifest.sh"] = apply_count_tokens(
        template("stations-manifest.sh.in", "@@TILE_EMITS@@", emits.rstrip("\n")), rows
    )

    groups: dict[int, list[str]] = {}
    for row in sorted(production, key=lambda x: x["runtime"]["bringUpOrder"]):
        groups.setdefault(row["render"]["bringUpGroup"], []).append(row["stationDir"])
    bring = "TILES=(\n" + "".join("  " + " ".join(groups[g]) + "\n" for g in sorted(groups)) + ")"
    out["streamhost/bring-up-all.sh"] = apply_count_tokens(
        template("bring-up-all.sh.in", "@@BRING_UP_TILES@@", bring), rows
    )

    build_rows = [item for row in rows for item in row.get("build", {}).get("rows", [])]
    build_rows += globals_doc.get("sharedBuildRows", [])
    build_rows.sort(key=lambda item: item["order"])
    widths = build_line_widths(build_rows)
    manifest = "".join(item.get("prelude", "") + render_build_line(item, widths) for item in build_rows).rstrip("\n")
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

    binding_rows = [r for r in rows if r.get("enabled") and "bindingOrder" in r["render"]]
    id_width = max(len(r["id"]) for r in binding_rows) + 1
    bindings = "".join(
        r["render"].get("bindingPrelude", "") + render_binding_line(r, id_width)
        for r in sorted(binding_rows, key=lambda x: x["render"]["bindingOrder"])
    )
    out["spa/src/three/archetypeRegistry.ts"] = apply_count_tokens(
        template("archetypeRegistry.ts.in", "@@OS_BINDINGS@@", bindings.rstrip("\n")), rows
    )
    out["spa/src/data/posterIndex.ts"] = render_poster_index(posters)
    out["spa/src/data/demoPrograms.ts"] = render_demo_programs(rows)
    out["spa/src/data/keyboards.ts"] = render_keyboards(rows)

    declarations = OrderedDict(
        [
            ("_generated_by", "scripts/stations-registry.py"),
            ("_schema", "declared tile capabilities; labctl gen adds observed state"),
            ("tiles", OrderedDict()),
        ]
    )
    for row in sorted(streamed, key=lambda x: x["stationDir"]):
        labctl = row.get("operator", {}).get("labctl", {})
        declarations["tiles"][row["stationDir"]] = OrderedDict((k, labctl.get(k)) for k in LABCTL_KEYS)
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
    # drift nothing on labhost notices: the station is active, its ticket is
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


def cmd_generate() -> int:
    outputs = generated()
    for rel, data in outputs.items():
        atomic_write(REPO / rel, data)
        print(f"generated {rel}")
    return 0
