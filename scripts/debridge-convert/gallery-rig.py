#!/usr/bin/env python3
"""Publish / withdraw a conversion rig in the DEPLOYED gallery (darklaunch).

The spike's gallery-arms.py, carried over to the conversion campaign
(docs/lab/DEBRIDGE-CONVERSION-BRIEF.md §5): a converted-station rig under
/data/vms/soltest/debridge-<station>/ gets a `/os/dbr-<station>` row for the
operator's side-by-side eyeball while the LIVE station keeps serving. Same
structural reasons keep rigs out of the registry (gen_tiles_json hard-exits on
a row with no /data/vms/streamhost/stations/ dir; the SPA tests demand exhibit
identity a rig must not invent) — see gallery-arms.py's header for the full
argument. Additive and surgical: only `dbr-*` rows this table names are ever
touched, and the darklaunch declaration (serve/darklaunch.d/debridge-rigs.json,
separate from the spike's debridge-arms.json) names exactly what is deployed so
verify-box-sync.sh reports DARKLAUNCH (green), never DIFFERS.

REVERT (removes the rows, leaves the rig running)
    gallery-rig.py withdraw [id ...]

USAGE
    gallery-rig.py publish | withdraw | status [id ...] [--serve-root DIR]

Run it ON THE BOX; the defaults are box paths.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SERVE_ROOT = "/data/vms/streamhost/serve"
SOLTEST = "/data/vms/soltest"
DARKLAUNCH_NAME = "debridge-rigs"

# One entry per campaign rig. Display identity mirrors the real station's
# registry entry with the rig-ness stated loudly; `order` parks far above the
# lineup (spike arms took 900/901) so it can never collide with a station.
RIGS = {
    "dbr-dragon32": {
        "rig_dir": f"{SOLTEST}/debridge-dragon32",
        "order": 910,
        "era_year": 1980,
        "year": 1982,
        "displayName": "Dragon 32 — host-native rig",
        "eraLabel": "1982 · de-bridging rig (host-native)",
        "lineage": "Dragon Data (Port Talbot, Wales) — Motorola 6809 / MC6847",
        "arch": "Motorola MC6809E, 0.89 MHz, 32 KB RAM, 16 KB ROM",
        "accent": "#30D200",
        "era": "1980s",
        "eraSoftware": ["Microsoft 16K Extended Color BASIC in ROM"],
        "periodBrowser": "none — pre-web 8-bit era",
        "iconicApps": ["Microsoft Extended Color BASIC"],
        "blurb": "Conversion-campaign rig: the dragon32 station's MAME driver "
        "host-native (drawshm frames, ctlsock keys, FIFO audio) — the live "
        "station keeps serving until cutover.",
        "notes": "De-bridging conversion rig, NOT an exhibit. Soft-hidden from "
        "the grid and the hall; reachable only at /os/dbr-dragon32. Published "
        "by scripts/debridge-convert/gallery-rig.py.",
    },
}


def darklaunch_path(serve: Path) -> Path:
    return serve / "darklaunch.d" / f"{DARKLAUNCH_NAME}.json"


def read_signaling(rig_dir: Path, rig_id: str) -> dict:
    """The rig's own signaling.json is the authority for id and UDP port."""
    doc = json.loads((rig_dir / "signaling.json").read_text())
    tile = doc.get("tile")
    if tile != rig_id:
        sys.exit(f"{rig_dir}/signaling.json: tile is {tile!r}, expected {rig_id!r} — wrong rig?")
    port = doc.get("udpPort")
    if not isinstance(port, int):
        sys.exit(f"{rig_dir}/signaling.json: no integer udpPort")
    hash_file = rig_dir / "cert_hash_b64.txt"
    if not hash_file.is_file():
        sys.exit(f"{hash_file}: absent — is the rig's streamhost running?")
    return {"udpPort": port, "hashFile": str(hash_file)}


def manifest_entry(rig_id: str, rig: dict) -> dict:
    """A minimal but SPA-valid lineup row; `listed: false` is the whole point."""
    return {
        "id": rig_id,
        "era_year": rig["era_year"],
        "displayName": rig["displayName"],
        "year": rig["year"],
        "lineage": rig["lineage"],
        "arch": rig["arch"],
        "accent": rig["accent"],
        "archetypeId": "beige-tower-crt",
        "transport": "streamhost",
        "order": rig["order"],
        "eraLabel": rig["eraLabel"],
        "signalEndpoint": f"/signal/{rig_id}.json",
        "listed": False,
        "notes": rig["notes"],
        "era": rig["era"],
        "eraSoftware": rig["eraSoftware"],
        "periodBrowser": rig["periodBrowser"],
        "iconicApps": rig["iconicApps"],
        "blurb": rig["blurb"],
    }


def write_json(path: Path, doc: dict, indent: int) -> None:
    tmp = path.with_name(f".{path.name}.dbr-tmp")
    tmp.write_text(json.dumps(doc, indent=indent, ensure_ascii=False) + "\n")
    tmp.replace(path)


def load(path: Path) -> dict:
    if not path.is_file():
        sys.exit(f"{path}: not found — wrong --serve-root?")
    return json.loads(path.read_text())


def write_declaration(serve: Path, tiles: dict) -> None:
    """(Re)write the declaration from the rows ACTUALLY overlaid (never RIGS)."""
    decl_path = darklaunch_path(serve)
    present = sorted(set(RIGS) & set(tiles))
    if not present:
        decl_path.unlink(missing_ok=True)
        print(f"removed {decl_path}")
        return
    decl_path.parent.mkdir(parents=True, exist_ok=True)
    decl = {
        "darklaunch": DARKLAUNCH_NAME,
        "owner": str(Path(__file__).resolve()),
        "note": "de-bridging conversion rigs ("
        + ", ".join(f"/os/{r}" for r in present)
        + "); revert with: gallery-rig.py withdraw",
        "files": {
            str(serve / "tiles.json"): {"kind": "json-object-keys", "ids": present},
            str(serve / "webroot" / "gallery-manifest.json"): {"kind": "json-entries", "ids": present},
        },
    }
    write_json(decl_path, decl, 2)
    print(f"declared darklaunch: {decl_path} ids={present}")


def select_rigs(ids: list[str]) -> dict[str, dict]:
    if not ids:
        return dict(RIGS)
    bad = set(ids) - set(RIGS)
    if bad:
        sys.exit(f"unknown rig id(s): {sorted(bad)} — known: {sorted(RIGS)}")
    return {rig_id: RIGS[rig_id] for rig_id in ids}


def cmd_publish(serve: Path, ids: list[str]) -> int:
    tiles_path = serve / "tiles.json"
    manifest_path = serve / "webroot" / "gallery-manifest.json"
    tiles = load(tiles_path)
    manifest = load(manifest_path)
    selected = select_rigs(ids)

    rows = {rig_id: read_signaling(Path(rig["rig_dir"]), rig_id) for rig_id, rig in selected.items()}

    for rig_id, rig in selected.items():
        tiles[rig_id] = rows[rig_id]
        manifest["entries"] = [e for e in manifest["entries"] if e.get("id") != rig_id]
        manifest["entries"].append(manifest_entry(rig_id, rig))
    manifest["entries"].sort(key=lambda e: e.get("order", 0))

    write_json(tiles_path, tiles, 2)
    write_json(manifest_path, manifest, 2)
    write_declaration(serve, tiles)

    for rig_id in selected:
        print(f"published {rig_id}: udp {rows[rig_id]['udpPort']}  /os/{rig_id}")
    return 0


def cmd_withdraw(serve: Path, ids: list[str]) -> int:
    tiles_path = serve / "tiles.json"
    manifest_path = serve / "webroot" / "gallery-manifest.json"
    tiles = load(tiles_path)
    manifest = load(manifest_path)
    withdraw_ids = set(select_rigs(ids))

    removed = sorted(withdraw_ids & set(tiles))
    for rig_id in withdraw_ids:
        tiles.pop(rig_id, None)
    before = len(manifest["entries"])
    manifest["entries"] = [e for e in manifest["entries"] if e.get("id") not in withdraw_ids]

    write_json(tiles_path, tiles, 2)
    write_json(manifest_path, manifest, 2)
    write_declaration(serve, tiles)

    print(f"withdrew signaling rows: {removed or 'none'}")
    print(f"withdrew manifest entries: {before - len(manifest['entries'])}")
    print("the rig itself is untouched")
    return 0


def cmd_status(serve: Path) -> int:
    tiles = load(serve / "tiles.json")
    manifest = load(serve / "webroot" / "gallery-manifest.json")
    listed = {e["id"]: e for e in manifest["entries"] if e.get("id") in RIGS}
    for rig_id, rig in RIGS.items():
        sig = Path(rig["rig_dir"]) / "signaling.json"
        entry = listed.get(rig_id)
        print(
            f"{rig_id:<14} signal-row={'yes' if rig_id in tiles else 'NO ':<3} "
            f"manifest={'yes' if entry else 'NO '} listed={entry.get('listed') if entry else '-'} "
            f"rig-signaling={'present' if sig.is_file() else 'ABSENT'}"
        )
    print(f"darklaunch declaration: {'present' if darklaunch_path(serve).is_file() else 'absent'}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("publish", "withdraw", "status"))
    ap.add_argument("rig", nargs="*", help="rig id(s) to act on (default: all)")
    ap.add_argument("--serve-root", default=SERVE_ROOT)
    args = ap.parse_args()
    if args.command == "status":
        return cmd_status(Path(args.serve_root))
    handler = {"publish": cmd_publish, "withdraw": cmd_withdraw}[args.command]
    return handler(Path(args.serve_root), args.rig)


if __name__ == "__main__":
    sys.exit(main())
