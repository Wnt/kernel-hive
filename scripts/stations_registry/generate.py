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
from datetime import date
from pathlib import Path
from typing import Any

from poster_registry import PosterError, load_posters
from serve.walkin.naming import SLOT_MAX as WALKIN_SLOT_MAX
from serve.walkin.naming import SLOT_MIN as WALKIN_SLOT_MIN

from .constants import GENERATED_SHELL, LABCTL_KEYS, NEW_TILE_SLOT_FLOOR, POSTERS, REGISTRY, REPO, TEMPLATES, TILES
from .loading import RegistryError, load
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


def scaffold_template(name: str, values: dict[str, str]) -> bytes:
    text = (TEMPLATES / name).read_text()
    for key, value in values.items():
        text = text.replace(f"@@{key}@@", value)
    leftovers = sorted(set(re.findall(r"@@[A-Z0-9_]+@@", text)))
    if leftovers:
        raise RegistryError(f"unfilled scaffold placeholders in {name}: {', '.join(leftovers)}")
    return text.encode()


def placeholder_hero(os_id: str) -> bytes:
    """A 1024x768 black WebP carrying the id, so a promoted entry has a hero to validate."""
    from io import BytesIO

    from PIL import Image, ImageDraw

    image = Image.new("RGB", (1024, 768), "black")
    draw = ImageDraw.Draw(image)
    draw.text((32, 32), f"{os_id}\nPLACEHOLDER hero", fill="white")
    buffer = BytesIO()
    image.save(buffer, format="WEBP", quality=60)
    return buffer.getvalue()


def _reserve_slot(globals_doc: dict, rows: list[dict], slot_arg: str) -> tuple[int, int]:
    """Shared --slot auto/explicit reservation logic for `new` and `new --like`."""
    used_slots = {row.get("stream", {}).get("slot") for row in rows}
    used_slots.discard(None)
    ports = globals_doc["ports"]
    relay_low = ports.get("publicRelayLow")
    relay_high = ports.get("publicRelayHigh")

    if slot_arg == "auto":
        slot = next(
            (
                value
                for value in range(NEW_TILE_SLOT_FLOOR, 11536)
                if value not in used_slots and slot_refusal(globals_doc, value) is None
            ),
            None,
        )
        if slot is None:
            raise RegistryError(
                f"--slot auto found nothing usable at or above {NEW_TILE_SLOT_FLOOR}: every "
                f"candidate is taken, inside the walk-in reservation "
                f"{WALKIN_SLOT_MIN}-{WALKIN_SLOT_MAX}, or outside the relay window "
                f"{relay_low}-{relay_high}. Re-cut the reservation or widen the relay window "
                "(edge nftables, the wg0.conf comment, docs/PUBLIC-GALLERY.md and "
                "publicRelayHigh move together), then retry."
            )
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
        refusal = slot_refusal(globals_doc, slot)
        if refusal:
            raise RegistryError(f"slot {slot}: {refusal}")
    udp_port = globals_doc["ports"]["productionBase"] + slot
    if any(row.get("stream", {}).get("udpPort") == udp_port for row in rows):
        raise RegistryError(f"UDP port {udp_port} is already in use")
    return slot, udp_port


_LIKE_REWRITE_PATTERNS = [
    (r"/data/vms/streamhost/stations/{sib}/", "/data/vms/streamhost/stations/{new}/"),
    (r"stations/{sib}/", "stations/{new}/"),
    (r"-name streamhost-{sib}", "-name streamhost-{new}"),
    (r"\$T/{sib}/", "$T/{new}/"),
    (r"guests/{sib}\.md", "guests/{new}.md"),
    (r"guest/{sib}\b", "guest/{new}"),
    (r"{sib}-current", "{new}-current"),
]


def _rewrite_like_text(text: str, sib: str, new_id: str) -> str:
    esc = re.escape(sib)
    for pattern, replacement in _LIKE_REWRITE_PATTERNS:
        text = re.sub(pattern.format(sib=esc), replacement.format(new=new_id), text)
    # Any JSON string that is EXACTLY the sibling id (id, stationDir, museum.id,
    # operator.actionMap.key, build.rows[].value.key, runtime.stationEnv.SH_STATION, ...)
    text = re.sub(rf'"{esc}"', f'"{new_id}"', text)
    return text


def _next_order(rows: list[dict], *path: str) -> int:
    """max(existing values at this dotted render/runtime path) + 1, over ALL rows."""
    best = 0
    for row in rows:
        node: Any = row
        for key in path:
            if not isinstance(node, dict) or key not in node:
                node = None
                break
            node = node[key]
        if isinstance(node, int) and not isinstance(node, bool):
            best = max(best, node)
    return best + 1


def cmd_new_like(os_id: str, sib_id: str, slot_arg: str, production: bool) -> int:
    """Scaffold a new station as a rewritten deep copy of a proven sibling's
    registry row, launcher and env fixture, instead of the bare Tier N template
    the coordinator otherwise hand-edits field by field."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", os_id):
        raise RegistryError("new id must match [a-z0-9][a-z0-9-]*")
    globals_doc, rows = load()
    if any(row["id"] == os_id for row in rows):
        raise RegistryError(f"tile {os_id!r} already exists")
    sib = next((row for row in rows if row["id"] == sib_id), None)
    if sib is None:
        raise RegistryError(f"--like sibling {sib_id!r} not found in the registry")

    slot, udp_port = _reserve_slot(globals_doc, rows, slot_arg)

    sib_clean = {k: v for k, v in sib.items() if not str(k).startswith("_")}
    text = json.dumps(sib_clean, indent=2, ensure_ascii=False)
    text = _rewrite_like_text(text, sib_id, os_id)
    row: dict = json.loads(text)

    row["era_year"] = date.today().year
    row.setdefault("stream", {})["experimentSlot"] = sib.get("stream", {}).get("experimentSlot")
    if row["stream"].get("experimentSlot") is None:
        row["stream"].pop("experimentSlot", None)
    row["stream"]["slot"] = slot
    row["stream"]["udpPort"] = udp_port
    row["stream"].pop("legacyPortException", None)
    row["lifecycle"] = "production" if production else "candidate"
    row["enabled"] = bool(production)

    render = row.setdefault("render", {})
    for path in (
        ("signalOrder",),
        ("stationsManifestOrder",),
        ("bindingOrder",),
        ("goldenOrder",),
        ("actionMapOrder",),
        ("mockManifestOrder",),
    ):
        if path[0] in render:
            render[path[0]] = _next_order(rows, "render", *path)
    render["stationsManifestPrelude"] = (
        f"\n# {os_id} (VMID {row.get('runtime', {}).get('vmidLabel', slot)}) — TODO one line; "
        f"scaffolded from {sib_id}.\n"
    )
    render["bindingPrelude"] = ""

    runtime = row.get("runtime", {})
    # load() merges the fixture's keys into runtime.stationEnv for every row it
    # returns, so `sib`'s copy already carries them. Strip those back out before
    # writing, or the fresh load of the new row's own fixture double-defines them.
    fixture_owned = set(sib.get("_fixtureEnv", {}))
    if fixture_owned and "stationEnv" in runtime:
        runtime["stationEnv"] = {k: v for k, v in runtime["stationEnv"].items() if k not in fixture_owned}
    if "bringUpOrder" in runtime:
        runtime["bringUpOrder"] = _next_order(rows, "runtime", "bringUpOrder")
    if "vmidLabel" in runtime:
        runtime["vmidLabel"] = slot
    station_env = runtime.get("stationEnv", {})
    if "SH_PORT" in station_env:
        station_env["SH_PORT"] = str(udp_port)
    qemu = runtime.get("qemu", {})
    emit_args = qemu.get("emitArgs", [])
    for i, _arg in enumerate(emit_args):
        if i == 0:
            continue
        if emit_args[i - 1] == "--tile":
            emit_args[i] = os_id
        elif emit_args[i - 1] == "--vmid":
            emit_args[i] = str(slot)
        elif emit_args[i - 1] == "--udp":
            emit_args[i] = str(udp_port)
    qemu["deviceSetId"] = f"{os_id}-current"

    if "reset" in row:
        row["reset"]["stationDir"] = os_id

    # build.rows[].value.key was already rewritten by the exact-string pass above.
    if row.get("build", {}).get("rows"):
        order = (
            max(
                (item["order"] for r in rows for item in r.get("build", {}).get("rows", [])),
                default=0,
            )
            + 1
        )
        first_row = row["build"]["rows"][0]
        first_row["order"] = order
        first_row.pop("defaultOrder", None)

    for field in (
        ("museum", "displayName"),
        ("museum", "blurb"),
        ("museum", "notes"),
        ("museum", "lineage"),
        ("spa", "eraLabel"),
    ):
        node = row
        for k in field[:-1]:
            node = node.get(k, {})
        leaf = field[-1]
        if leaf in node and isinstance(node[leaf], str):
            node[leaf] = f"TODO({sib_id}): " + node[leaf]

    row["notes"] = [f"scaffolded from {sib_id} on {date.today().isoformat()}; TODO: media, museum, spa"]

    registry_path = TILES / f"{os_id}.json"
    guest_path = REPO / row["guestDoc"]
    coldboot_path = REPO / "scripts/coldboot" / f"{os_id}-bootrec-arm.sh"
    poster_path = POSTERS / f"{os_id}.md"
    hero_path = REPO / "spa/public/posters" / os_id / "desktop.webp"
    builder_path = REPO / "scripts/build-guests/tiles" / f"{os_id}.sh"
    station_dir = REPO / "streamhost/stations" / os_id
    launcher_path = station_dir / "qemu-streamhost.sh"
    fixture_path = station_dir / "station.env.fixture"
    sib_dir = REPO / "streamhost/stations" / sib_id
    like_paths = (
        registry_path,
        guest_path,
        coldboot_path,
        poster_path,
        hero_path,
        builder_path,
        launcher_path,
        fixture_path,
    )
    for path in like_paths:
        if path.exists():
            raise RegistryError(f"refusing to overwrite existing {path.relative_to(REPO)}")
    for src in (sib_dir / "qemu-streamhost.sh", sib_dir / "station.env.fixture"):
        if not src.is_file():
            raise RegistryError(f"sibling {sib_id!r} is missing {src.relative_to(REPO)}")

    values = {
        "OS_ID": os_id,
        "TILE_DIR": os_id,
        "TIER": "1",
        "SLOT": str(slot),
        "UDP_PORT": str(udp_port),
        "ARCHETYPE": row.get("spa", {}).get("archetypeId", ""),
    }
    launcher_text = _rewrite_like_text((sib_dir / "qemu-streamhost.sh").read_text(), sib_id, os_id)
    fixture_text = _rewrite_like_text((sib_dir / "station.env.fixture").read_text(), sib_id, os_id)
    scaffold_files: OrderedDict[Path, bytes] = OrderedDict(
        [
            (registry_path, (json.dumps(row, indent=2, ensure_ascii=False) + "\n").encode()),
            (builder_path, scaffold_template("new-os-builder-tier1.sh.in", values)),
            (guest_path, scaffold_template("new-os-guest.md.in", values)),
            (coldboot_path, scaffold_template("new-os-coldboot-arm.sh.in", values)),
            (poster_path, scaffold_template("new-os-poster.md.in", values)),
            (hero_path, placeholder_hero(os_id)),
            (launcher_path, launcher_text.encode()),
            (fixture_path, fixture_text.encode()),
        ]
    )
    try:
        for path, data in scaffold_files.items():
            atomic_write(path, data)
        os.chmod(builder_path, 0o755)
        os.chmod(launcher_path, 0o755)
        cmd_generate()
    except Exception:
        for path in scaffold_files:
            path.unlink(missing_ok=True)
        raise
    print(f"scaffolded {os_id} --like {sib_id}: slot={slot} udp={udp_port} production={production}")
    for path in scaffold_files:
        print(f"  {path.relative_to(REPO)}")
    print("candidate carries TODO-tagged sibling prose; run `stations-registry.py validate` after edits")
    return 0


def cmd_new(os_id: str, tier: int, archetype: str, slot_arg: str) -> int:
    """Create an inert candidate scaffold (registry row, builder, guest doc, cold-boot arm,
    poster prose + placeholder hero, and for tier 1 the station launcher + env fixture),
    then regenerate canonical outputs."""
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
    ports = globals_doc["ports"]
    relay_low = ports.get("publicRelayLow")
    relay_high = ports.get("publicRelayHigh")

    if slot_arg == "auto":
        slot = next(
            (
                value
                for value in range(NEW_TILE_SLOT_FLOOR, 11536)
                if value not in used_slots and slot_refusal(globals_doc, value) is None
            ),
            None,
        )
        if slot is None:
            raise RegistryError(
                f"--slot auto found nothing usable at or above {NEW_TILE_SLOT_FLOOR}: every "
                f"candidate is taken, inside the walk-in reservation "
                f"{WALKIN_SLOT_MIN}-{WALKIN_SLOT_MAX}, or outside the relay window "
                f"{relay_low}-{relay_high}. Re-cut the reservation or widen the relay window "
                "(edge nftables, the wg0.conf comment, docs/PUBLIC-GALLERY.md and "
                "publicRelayHigh move together), then retry."
            )
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
        refusal = slot_refusal(globals_doc, slot)
        if refusal:
            raise RegistryError(f"slot {slot}: {refusal}")
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
            ("script", f"tiles/{os_id}.sh"),
            ("outputDir", output_dir),
            ("class", build_class),
            ("estimated", estimated),
            ("automation", automation),
            ("produces", "TODO"),
            ("flags", []),
        ]
    )
    row = OrderedDict(
        [
            ("schemaVersion", 1),
            ("id", os_id),
            ("era_year", date.today().year),
            ("stationDir", os_id),
            ("lifecycle", "candidate"),
            ("enabled", False),
            ("build", {"rows": [{"order": build_order, "prelude": "", "value": line_value}]}),
            ("operator", {}),
            ("render", {}),
            # A disabled candidate reserves identity/slot/port without entering any
            # generated runtime surface. Promotion changes transport to streamhost and
            # fills runtime/reset/render after the builder and golden are proven.
            # `pointer` is required on EVERY entry, posters included, so the
            # scaffold has to declare one or `new` emits a row that its own
            # `validate` rejects. A disabled candidate has no proven input path
            # yet, so it declares the honest none-pointer a showcase row uses;
            # promotion replaces it with the measured transport/backend.
            (
                "stream",
                {
                    "transport": "showcase",
                    "udpPort": udp_port,
                    "slot": slot,
                    "pointer": {
                        "transport": "none",
                        "method": "none",
                        "absolute": False,
                        "present": False,
                        "device": "none",
                        "scale": 1.0,
                        "offset": [0, 0],
                    },
                },
            ),
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
    poster_path = POSTERS / f"{os_id}.md"
    hero_path = REPO / "spa/public/posters" / os_id / "desktop.webp"
    station_dir = REPO / "streamhost/stations" / os_id
    launcher_path = station_dir / "qemu-streamhost.sh"
    fixture_path = station_dir / "station.env.fixture"
    sidecars = [poster_path, hero_path] + ([launcher_path, fixture_path] if tier == 1 else [])
    for path in (registry_path, builder_path, guest_path, coldboot_path, *sidecars):
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
            # The sidecars validate demands the moment the entry is promoted: poster
            # prose and a hero image, plus (tier 1) the launcher and env fixture the
            # coordinator otherwise hand-copies from a sibling station.
            (poster_path, scaffold_template("new-os-poster.md.in", values)),
            (hero_path, placeholder_hero(os_id)),
        ]
    )
    if tier == 1:
        scaffold_files[launcher_path] = scaffold_template("new-os-qemu-streamhost.sh.in", values)
        scaffold_files[fixture_path] = scaffold_template("new-os-station.env.fixture.in", values)
    try:
        for path, data in scaffold_files.items():
            atomic_write(path, data)
        os.chmod(builder_path, 0o755)
        if tier == 1:
            os.chmod(launcher_path, 0o755)
        # A scaffold is an ordinary canonical registry change: leave generated
        # files current so `make station-registry-check` passes immediately.
        cmd_generate()
    except Exception:
        for path in scaffold_files:
            path.unlink(missing_ok=True)
        raise
    print(f"scaffolded {os_id}: tier={tier} archetype={archetype} slot={slot} udp={udp_port}")
    print(f"  registry/stations/{os_id}.json")
    print(f"  scripts/build-guests/tiles/{os_id}.sh")
    print(f"  docs/guests/{os_id}.md")
    print(f"  scripts/coldboot/{os_id}-bootrec-arm.sh")
    for path in sidecars:
        print(f"  {path.relative_to(REPO)}")
    print("candidate is disabled; fill TODOs and prove its golden before promotion")
    return 0


def cmd_generate() -> int:
    outputs = generated()
    for rel, data in outputs.items():
        atomic_write(REPO / rel, data)
        print(f"generated {rel}")
    return 0
