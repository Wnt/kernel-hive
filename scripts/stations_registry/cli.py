"""CLI subcommands (except `new`, which lives with the generator in generate.py) and main()."""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
from collections import OrderedDict
from pathlib import Path

from .constants import LABCTL_KEYS, RENDER_DIR, REPO
from .facts_live import cmd_facts_live
from .generate import atomic_write, check_gate_lists, cmd_generate, cmd_new, generated
from .loading import RegistryError, is_x11_runtime, load
from .render import rendered
from .validate_rules import validate


def cmd_render(out_dir: str | None) -> int:
    """Write the rendered (never-committed) artifacts into a build directory."""
    root = Path(out_dir) if out_dir else REPO / RENDER_DIR
    if not root.is_absolute():
        root = REPO / root
    for name, data in rendered().items():
        atomic_write(root / name, data)
        print(f"rendered {root / name}")
    return 0


def cmd_emit(name: str) -> int:
    """Stream ONE artifact to stdout — no file at rest anywhere on the way."""
    wanted = name.removeprefix(f"{RENDER_DIR}/").removeprefix("./")
    outputs = rendered()
    if wanted not in outputs:
        outputs.update(generated())
        if wanted not in outputs:
            raise RegistryError(f"unknown artifact {name!r}; known: {', '.join(outputs)}")
    try:
        sys.stdout.buffer.write(outputs[wanted])
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        # `emit index.json | head` closes the pipe early. That is the reader
        # being done, not a failure — and without the devnull redirect Python
        # prints its own broken-pipe complaint at shutdown on top of it.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    return 0


def compare_live_labctl(outputs: OrderedDict[str, bytes]) -> list[str]:
    live = Path("/data/vms/streamhost/stations.json")
    if not live.exists():
        return ["SKIP live labctl semantic check (/data/vms/streamhost/stations.json absent)"]
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
    # The rendered documents have nothing in the tree to compare against, so the
    # check that matters is that they still RENDER — a broken emitter must fail
    # here, not at publish time with the gallery already half-deployed.
    for name, data in rendered().items():
        print(f"RENDERED {RENDER_DIR}/{name} ({len(data)} bytes, not committed)")
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


def cmd_paths(want_rendered: bool) -> int:
    """Print the authoritative list of output paths (one per line)."""
    if want_rendered:
        for name in rendered():
            print(f"{RENDER_DIR}/{name}")
        return 0
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
            # "why is this exhibit not on the floor" is the first thing a session
            # asks about a station it cannot find in the grid; answer it up front.
            ("listing", row.get("listing", {"state": "listed"})),
            ("stationDir", row.get("stationDir")),
            (
                "signal",
                {
                    "udpPort": row.get("stream", {}).get("udpPort"),
                    "hashFile": f"/data/vms/streamhost/stations/{row.get('stationDir')}/cert_hash_b64.txt"
                    if row.get("stationDir")
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
    sub.add_parser("facts-live", help="check registry retronet claims against the live box (SKIPs if unreachable)")
    paths = sub.add_parser("paths")
    paths.add_argument(
        "--rendered",
        action="store_true",
        help="list the rendered (never-committed) artifacts instead of the generated ones",
    )
    render = sub.add_parser("render", help="write the rendered artifacts into a build dir")
    render.add_argument("--out", help=f"output directory (default: {RENDER_DIR})")
    emit = sub.add_parser("emit", help="stream ONE artifact to stdout")
    emit.add_argument("name", help="e.g. gallery-manifest.json, index.json, scripts/serve/tiles.json")
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
        if command == "facts-live":
            return cmd_facts_live()
        if command == "generate":
            return cmd_generate()
        if command == "check":
            return cmd_check()
        if command == "paths":
            return cmd_paths(ns.rendered)
        if command == "render":
            return cmd_render(ns.out)
        if command == "emit":
            return cmd_emit(ns.name)
        if command == "explain":
            return cmd_explain(ns.id)
        if command == "new":
            return cmd_new(ns.id, ns.tier, ns.archetype, ns.slot)
        ap.print_help()
        return 2
    except (RegistryError, OSError, ValueError, SyntaxError) as exc:
        print(f"tile-registry: ERROR: {exc}", file=sys.stderr)
        return 1
