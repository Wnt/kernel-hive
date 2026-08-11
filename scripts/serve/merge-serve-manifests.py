#!/usr/bin/env python3
"""Additively merge ONE tile's rows into the three live serve documents.

WHY THIS EXISTS
---------------
`scripts/serve-https-spa.sh manifests` does a WHOLESALE atomic replace of
`tiles.json`, `gallery-manifest.json` and `golden-manifest.json` from the
publishing worktree. With parallel tile work in flight that silently deletes
every tile a sibling worktree published first -- it happened twice on
2026-08-10, and the symptom is nasty: the victim's `/signal/<tile>.json` starts
returning 404 and `POST /restore/<tile>` returns `unknown osId`, while the tile
itself runs perfectly and nothing logs a warning. The tile's owner then hunts a
fault that does not exist.

This tool touches ONE tile's row in each document and leaves every other row
alone, so concurrent agents cannot clobber each other. The integrator still does
a single wholesale regenerate+publish after the branches are merged; that is the
point at which all three documents become correct for everybody.

The HTTPS server reads these maps FRESH PER REQUEST, so a merge takes effect
with no restart.

USAGE
    scripts/serve/merge-serve-manifests.py <tile> \
        <my-tiles.json> <my-gallery-manifest.json> <my-golden-manifest.json>

The gallery manifest has no committed copy to point at: render one first with
`python3 scripts/tiles-registry.py render` (build/registry/gallery-manifest.json)
or `emit gallery-manifest.json > <path>`.

Run it ON THE BOX (the destinations are box paths; override with --serve-root
for a dry run against a copy).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

SERVE_ROOT = "/data/vms/streamhost/serve"


def detect_indent(path: Path) -> int:
    """Preserve the file's existing indent.

    Rewriting a document at a different indent than the generator uses turns
    every line into a diff and makes `verify-box-sync.sh` report the file as
    DRIFT against its committed reference -- a self-inflicted gate failure.
    """
    for line in path.read_text().splitlines()[1:]:
        if m := re.match(r"^( +)\S", line):
            return len(m.group(1))
    return 1


def merge_one(tile: str, src: Path, dst: Path, kind: str, backup: bool) -> None:
    mine = json.loads(src.read_text())
    live = json.loads(dst.read_text())

    if kind == "map":
        if tile not in mine:
            sys.exit(f"{src}: no row for {tile!r}")
        live[tile] = mine[tile]
    elif kind == "entries":
        row = next(
            (e for e in mine.get("entries", []) if tile in (e.get("osId"), e.get("id"))),
            None,
        )
        if row is None:
            sys.exit(f"{src}: no entry for {tile!r}")
        key = "osId" if "osId" in row else "id"
        live["entries"] = [e for e in live["entries"] if e.get(key) != tile] + [row]
        live["entries"].sort(key=lambda e: e.get("order", 0))
    else:
        if tile not in mine.get("tiles", {}):
            sys.exit(f"{src}: no tiles[{tile!r}]")
        live.setdefault("tiles", {})[tile] = mine["tiles"][tile]

    if backup:
        shutil.copy2(dst, f"{dst}.bak")
    tmp = f"{dst}.tmp"
    with open(tmp, "w") as f:
        json.dump(live, f, indent=detect_indent(dst), sort_keys=False)
        f.write("\n")
    json.loads(Path(tmp).read_text())  # never leave a corrupt live document
    os.replace(tmp, dst)
    print(f"merged {tile} -> {dst}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tile")
    ap.add_argument("tiles_json", type=Path)
    ap.add_argument("gallery_manifest", type=Path)
    ap.add_argument("golden_manifest", type=Path)
    ap.add_argument("--serve-root", default=SERVE_ROOT, type=Path)
    ap.add_argument("--no-backup", action="store_true", help="skip the .bak copies")
    args = ap.parse_args()

    root = Path(args.serve_root)
    for src, dst, kind in (
        (args.tiles_json, root / "tiles.json", "map"),
        (args.gallery_manifest, root / "webroot/gallery-manifest.json", "entries"),
        (args.golden_manifest, root / "golden-manifest.json", "tiles"),
    ):
        if not src.is_file():
            sys.exit(f"missing source: {src}")
        if not dst.is_file():
            sys.exit(f"missing live document: {dst}")
        merge_one(args.tile, src, dst, kind, backup=not args.no_backup)
    return 0


if __name__ == "__main__":
    sys.exit(main())
