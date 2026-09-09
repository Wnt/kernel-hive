"""The `stations-registry.py new <id> --like <sibling>` path.

Split out of scaffold.py (2026-09-09) when the file pushed past the file-size
hard cap. scaffold.py keeps the bare-template `new` path and the helpers both
paths share (`scaffold_template`, `placeholder_hero`, `_reserve_slot`); this
module owns everything specific to scaffolding a station as a rewritten deep
copy of a proven sibling.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from collections import OrderedDict
from datetime import date
from pathlib import Path
from typing import Any

from .constants import POSTERS, REPO, TILES
from .generate import atomic_write, cmd_generate
from .loading import RegistryError, load
from .scaffold import _reserve_slot, placeholder_hero, scaffold_template
from .spa_scene import (
    ASSEMBLIES_CONST,
    ASSEMBLIES_REL,
    TUPLE_PARTS,
    free_tuple_suggestions,
    read_table,
    tuple_of,
)

_LIKE_REWRITE_PATTERNS = [
    # `(?![a-z0-9])`, not a trailing slash: `operator.labctl.dir` is the bare station
    # dir with nothing after the id, and a slash-anchored pattern left it pointing at
    # the sibling (slackware's station-up, 2026-09-03).
    (r"/data/vms/streamhost/stations/{sib}(?![a-z0-9])", "/data/vms/streamhost/stations/{new}"),
    (r"stations/{sib}/", "stations/{new}/"),
    (r"-name streamhost-{sib}", "-name streamhost-{new}"),
    (r"\$T/{sib}/", "$T/{new}/"),
    (r"guests/{sib}\.md", "guests/{new}.md"),
    (r"guest/{sib}\b", "guest/{new}"),
    (r"{sib}-current", "{new}-current"),
    (r"{sib}_cmd\b", "{new}_cmd"),  # SH_X11_CMD_FILE of x11-runtime siblings
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


def refuse_inherited_tuple(sib_id: str, tuple_arg: str | None) -> None:
    """`--like` may not inherit the sibling's body|monitor|keyboard|mouse.

    machines.test.ts requires a DISTINCT hardware signature per station, so a
    copied tuple is a guaranteed red push — and it was, on every one of the nine
    waves of 2026-09-03, discovered at push time inside a serialised landing
    window. Refuse here instead, and hand over combinations that are actually
    free rather than leaving the operator to grep machines.ts.
    """
    if tuple_arg:
        return
    try:
        table = read_table(ASSEMBLIES_REL, ASSEMBLIES_CONST)
    except (RegistryError, OSError):  # pragma: no cover - no spa/ checkout
        return
    if sib_id not in table.blocks:
        return
    inherited = tuple_of(table.blocks[sib_id])
    free = free_tuple_suggestions(table, sib_id)
    raise RegistryError(
        f"--like {sib_id} would copy its hardware tuple {inherited}, and every station needs a "
        f"DISTINCT {'|'.join(TUPLE_PARTS)} (spa/src/scene/machines.test.ts). Pass "
        "--tuple body,monitor,keyboard,mouse. Free near the sibling: " + "; ".join(free)
    )


def insert_spa_rows(os_id: str, sib_id: str, tuple_arg: str | None, enabled: bool) -> None:
    """Put the station's two scene rows in at its lineup position, or say why not.

    Shelling out to scripts/dev/spa-scene-rows.py rather than reimplementing the
    rebuild keeps ONE writer for these two files — the same one station-land.sh
    calls, so the scaffold and the landing cannot disagree about placement.
    """
    if not enabled:
        print(f"  spa scene rows: skipped — {os_id} is a disabled candidate, not a lineup entry yet")
        print(f"    at promotion: scripts/dev/spa-scene-rows.py {os_id} --like {sib_id} --tuple ... --apply")
        return
    cmd = ["python3", str(REPO / "scripts/dev/spa-scene-rows.py"), os_id, "--like", sib_id, "--apply"]
    if tuple_arg:
        cmd += ["--tuple", tuple_arg]
    result = subprocess.run(cmd, cwd=str(REPO), capture_output=True, text=True, check=False)
    print("  spa scene rows:")
    for line in (result.stdout + result.stderr).splitlines():
        if line.lstrip().startswith(("wrote", "spa-scene-rows", "NOTE")):
            print(f"    {line.strip()}")
    if result.returncode != 0:
        raise RegistryError(f"spa-scene-rows.py refused the rows for {os_id}: {result.stderr.strip() or 'see above'}")


def cmd_new_like(os_id: str, sib_id: str, slot_arg: str, production: bool, tuple_arg: str | None = None) -> int:
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
    refuse_inherited_tuple(sib_id, tuple_arg)

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
    if "udp_port" in row.get("operator", {}).get("labctl", {}):
        row["operator"]["labctl"]["udp_port"] = udp_port  # labctl declares it (a1000 landing, 2026-09-09)
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
    x11_args = runtime.get("x11", {}).get("emitArgs", [])
    for i in range(1, len(x11_args)):
        if x11_args[i - 1] == "--tile":
            x11_args[i] = os_id
        elif x11_args[i - 1] == "--udp":
            x11_args[i] = str(udp_port)

    if "reset" in row:
        row["reset"]["stationDir"] = os_id

    # A retronet block is a LEDGER entry, not a shape to copy: address, MAC, ICQ
    # persona and roster row are all unique per station, so an inherited block
    # collides with the sibling on its first validate ("address is already taken
    # by <sibling>") and claims an icq plane no roster row backs. The station
    # joins the bridge later, through scripts/retronet/rn-onboard.sh, which is
    # what writes this block from the allocation it actually holds.
    row.pop("retronet", None)

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
    sib_launcher_rel = sib.get("runtime", {}).get("x11", {}).get("launcher", "")
    sib_launcher = Path(sib_launcher_rel).name or "qemu-streamhost.sh"
    fixture_path = station_dir / "station.env.fixture"
    sib_dir = REPO / "streamhost/stations" / sib_id
    # A host-native sibling (mame-native, fsuae-native, vice-native) names a
    # launcher SHARED under streamhost/stations/<engine>/ rather than one of
    # its own; the new station keeps pointing at that shared file (the
    # emitter installs it via --x11-runtime-file), so there is nothing to
    # copy — the domainos wave (2026-09-09) hit "sibling 'samcoupe' is
    # missing streamhost/stations/samcoupe/x11-runtime.sh" here.
    shared_launcher = (
        bool(sib_launcher_rel) and not (sib_dir / sib_launcher).is_file() and (REPO / sib_launcher_rel).is_file()
    )
    launcher_path = None if shared_launcher else station_dir / sib_launcher
    like_paths = tuple(
        p
        for p in (
            registry_path,
            guest_path,
            coldboot_path,
            poster_path,
            hero_path,
            builder_path,
            launcher_path,
            fixture_path,
        )
        if p is not None
    )
    for path in like_paths:
        if path.exists():
            raise RegistryError(f"refusing to overwrite existing {path.relative_to(REPO)}")
    for src in ([] if shared_launcher else [sib_dir / sib_launcher]) + [sib_dir / "station.env.fixture"]:
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
    launcher_text = "" if shared_launcher else _rewrite_like_text((sib_dir / sib_launcher).read_text(), sib_id, os_id)
    fixture_text = _rewrite_like_text((sib_dir / "station.env.fixture").read_text(), sib_id, os_id)
    scaffold_files: OrderedDict[Path, bytes] = OrderedDict(
        [
            (registry_path, (json.dumps(row, indent=2, ensure_ascii=False) + "\n").encode()),
            (builder_path, scaffold_template("new-os-builder-tier1.sh.in", values)),
            (guest_path, scaffold_template("new-os-guest.md.in", values)),
            (coldboot_path, scaffold_template("new-os-coldboot-arm.sh.in", values)),
            (poster_path, scaffold_template("new-os-poster.md.in", values)),
            (hero_path, placeholder_hero(os_id)),
            (fixture_path, fixture_text.encode()),
        ]
    )
    if launcher_path is not None:
        scaffold_files[launcher_path] = launcher_text.encode()
    try:
        for path, data in scaffold_files.items():
            atomic_write(path, data)
        os.chmod(builder_path, 0o755)
        if launcher_path is not None:
            os.chmod(launcher_path, 0o755)
        # BEFORE cmd_generate(): generate runs validate(), and validate now fails
        # on a lineup entry with no scene rows. The rows depend only on the
        # registry file that is already written, so this is the right order, not
        # a workaround for the check.
        insert_spa_rows(os_id, sib_id, tuple_arg, bool(production))
        cmd_generate()
    except Exception:
        for path in scaffold_files:
            path.unlink(missing_ok=True)
        print(
            f"  rolled back the {os_id} scaffold. If the scene rows were written first, "
            f"drop {os_id} from spa/src/scene/{{assembliesByTile,machineIdentity}}.ts too.",
        )
        raise
    print(f"scaffolded {os_id} --like {sib_id}: slot={slot} udp={udp_port} production={production}")
    for path in scaffold_files:
        print(f"  {path.relative_to(REPO)}")
    print("candidate carries TODO-tagged sibling prose; run `stations-registry.py validate` after edits")
    return 0
