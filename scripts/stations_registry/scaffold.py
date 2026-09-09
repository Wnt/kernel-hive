"""Scaffold a new station: `stations-registry.py new <id> [--like <sibling>] [--production]`.

Split out of generate.py (2026-09-02) when the `--like` path pushed that module
past the file-size hard cap, then split again (2026-09-09) into this module —
the bare-template `new` path and the helpers both paths share — and
scaffold_like.py, which owns the `new --like <sibling>` path.
"""

from __future__ import annotations

import json
import os
import re
from collections import OrderedDict
from datetime import date

from serve.walkin.naming import SLOT_MAX as WALKIN_SLOT_MAX
from serve.walkin.naming import SLOT_MIN as WALKIN_SLOT_MIN

from .constants import NEW_TILE_SLOT_FLOOR, POSTERS, REPO, TEMPLATES, TILES
from .generate import atomic_write, cmd_generate, slot_refusal
from .loading import RegistryError, load


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
