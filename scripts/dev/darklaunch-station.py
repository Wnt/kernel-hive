#!/usr/bin/env python3
"""Dark-launch ONE sandbox station in the DEPLOYED gallery: /os/<id> resolves,
the grid and the 3D hall never see it.

This is the generic form of scripts/debridge-spike/gallery-arms.py (read its
docstring for why a sandbox rig cannot simply be a registry row). It overlays
one signaling row + one `listed: false` manifest entry onto the two live
runtime documents and declares exactly that in `serve/darklaunch.d/<id>.json`,
so scripts/dev/verify-box-sync.sh reports DARKLAUNCH (green, additive-only)
instead of DIFFERS. The HTTPS server re-reads both documents per request, so
nothing restarts.

`serve-https-spa.sh` republishes both documents from the registry, which used
to WIPE every overlay on the box — one wave's landing silently took seven other
waves' `/os/<id>` views down, every time, and the only repair was for each of
them to notice and re-run `publish`. It no longer does: each declaration now
carries the rows it added (`overlay`), and publish_manifests calls `reapply`
straight after it writes. `reapply` is idempotent and is the ONLY thing that
needs to run after a publish.

    darklaunch-station.py publish  <id> --rig DIR --like STATION [--display-name NAME]
    darklaunch-station.py publish  <id> --rig DIR --entry FILE   # FILE: manifest entry JSON
    darklaunch-station.py publish  <id> --rig DIR --like STATION --reset [--reset-mode M] [--snapshot S]
    darklaunch-station.py withdraw <id>
    darklaunch-station.py status   <id> [--rig DIR]
    darklaunch-station.py reapply                # re-overlay every declaration

`--rig DIR` is the sandbox station dir holding the daemon's `signaling.json`
and `cert_hash_b64.txt` (the daemon writes both; the rig's signaling.json is
the authority for id and UDP port). Run ON THE BOX; defaults are box paths.

`--like STATION` builds the manifest entry for you instead of requiring a
hand-written `--entry FILE`: it copies STATION's own row out of
`<serve>/webroot/gallery-manifest.json`, then sets id=<id>,
displayName="<id> (smoke rig)" (or --display-name), order=900, listed=false,
signalEndpoint=/signal/<id>.json. This is the guessing step the pcgeos
speedrun (2026-09-02) got wrong by hand — the sibling's row, not some other
manifest file, is the only correct template. `--entry` still works, for a
one-off shape `--like` cannot produce.

`--reset` also makes the gallery's "Restore to golden" button reach the rig: it
overlays a `golden-manifest.json` row (the allow-list POST /restore/<id> checks)
carrying `stationPath` = the rig dir and `stationEnv` = its env file
(station.env, else the smoke-rig stream.env), which reset-tile.sh reads instead
of /data/vms/streamhost/stations/<id>. Without it a dark station's Restore
answers 404 and the visitor sees nothing happen (nokia9300, 2026-09-25). The
rig's env file must declare an in-process reset (reset-tile.sh header,
SH_RESET_CTL_*): a rig has no streamhost@ unit, so reset-tile.sh never falls back
to restarting one.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SERVE_ROOT = "/data/vms/streamhost/serve"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")


def load(path: Path) -> dict:
    if not path.is_file():
        sys.exit(f"{path}: not found — wrong --serve-root?")
    return json.loads(path.read_text())


def write_json(path: Path, doc: dict) -> None:
    tmp = path.with_name(f".{path.name}.dl-tmp")
    tmp.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(path)


def read_signaling(rig: Path, station_id: str) -> dict:
    doc = json.loads((rig / "signaling.json").read_text())
    tile = doc.get("tile")
    if tile != station_id:
        sys.exit(f"{rig}/signaling.json: tile is {tile!r}, expected {station_id!r} — wrong rig?")
    port = doc.get("udpPort")
    if not isinstance(port, int):
        sys.exit(f"{rig}/signaling.json: no integer udpPort")
    hash_file = rig / "cert_hash_b64.txt"
    if not hash_file.is_file():
        sys.exit(f"{hash_file}: absent — is the rig's streamhost running?")
    return {"udpPort": port, "hashFile": str(hash_file)}


def golden_row(rig: Path, station_id: str, mode: str, snapshot: str | None) -> dict:
    env = next((rig / n for n in ("station.env", "stream.env") if (rig / n).is_file()), None)
    if env is None:
        sys.exit(f"{rig}: no station.env or stream.env — --reset needs the rig's env file")
    row = {"stationDir": station_id, "resetMode": mode, "stationPath": str(rig), "stationEnv": str(env)}
    if snapshot:
        row["snapshot"] = snapshot
    return row


def decl_path(serve: Path, station_id: str) -> Path:
    return serve / "darklaunch.d" / f"{station_id}.json"


def had_golden_overlay(serve: Path, station_id: str) -> bool:
    path = decl_path(serve, station_id)
    try:
        return bool((json.loads(path.read_text()).get("overlay") or {}).get("golden"))
    except (OSError, ValueError):
        return False


def write_declaration(
    serve: Path,
    station_id: str,
    present: bool,
    signal_row: dict | None = None,
    entry: dict | None = None,
    golden: dict | None = None,
) -> None:
    path = decl_path(serve, station_id)
    if not present:
        path.unlink(missing_ok=True)
        print(f"removed {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    write_json(
        path,
        {
            "darklaunch": station_id,
            "owner": str(Path(__file__).resolve()),
            "note": f"dark-launched sandbox station /os/{station_id}; "
            f"revert with: darklaunch-station.py withdraw {station_id}",
            "files": {
                str(serve / "tiles.json"): {"kind": "json-object-keys", "ids": [station_id]},
                str(serve / "webroot" / "gallery-manifest.json"): {"kind": "json-entries", "ids": [station_id]},
                **(
                    {str(serve / "golden-manifest.json"): {"kind": "json-tiles-keys", "ids": [station_id]}}
                    if golden
                    else {}
                ),
            },
            # THE PAYLOAD, not just the claim. `files` says WHICH ids this
            # overlay adds (that is all verify-box-sync.sh needs to subtract
            # them); `overlay` says WHAT they are, which is what makes the
            # overlay survivable across a republish. Without it a declaration
            # could only be re-applied by re-deriving the rows from a rig that
            # may be gone, so a publish was a one-way loss.
            "overlay": {"tiles": signal_row, "entry": entry, **({"golden": golden} if golden else {})},
        },
    )
    print(f"declared darklaunch: {path}")


def cmd_reapply(serve: Path) -> int:
    """Re-overlay every declaration onto the freshly published documents.

    Called by serve-https-spa.sh publish_manifests immediately after it writes
    tiles.json and gallery-manifest.json, so a deploy no longer costs every
    OTHER wave its dark launch. Idempotent: the rows are replaced, not appended.
    """
    decls = sorted((serve / "darklaunch.d").glob("*.json"))
    if not decls:
        print("darklaunch: no declarations, nothing to re-overlay")
        return 0
    tiles_path = serve / "tiles.json"
    manifest_path = serve / "webroot" / "gallery-manifest.json"
    golden_path = serve / "golden-manifest.json"
    tiles = load(tiles_path)
    manifest = load(manifest_path)
    golden_doc = json.loads(golden_path.read_text()) if golden_path.is_file() else None
    restored, legacy = [], []
    for decl_path in decls:
        try:
            decl = json.loads(decl_path.read_text())
            station_id = decl["darklaunch"]
        except (OSError, ValueError, KeyError) as exc:
            print(f"darklaunch: SKIP unreadable {decl_path} ({exc})")
            continue
        overlay = decl.get("overlay") or {}
        signal_row, entry = overlay.get("tiles"), overlay.get("entry")
        if not signal_row or not entry:
            legacy.append(station_id)
            continue
        tiles[station_id] = signal_row
        manifest["entries"] = [e for e in manifest["entries"] if e.get("id") != station_id] + [entry]
        if overlay.get("golden") and golden_doc is not None:
            golden_doc.setdefault("tiles", {})[station_id] = overlay["golden"]
        restored.append(station_id)
    manifest["entries"].sort(key=lambda e: e.get("order", 0))
    write_json(tiles_path, tiles)
    write_json(manifest_path, manifest)
    if golden_doc is not None:
        write_json(golden_path, golden_doc)
    print(f"darklaunch: re-overlaid {len(restored)} station(s): {', '.join(restored) or '-'}")
    for station_id in legacy:
        # LOUD: a declaration written before overlays carried their payload. The
        # rows are gone from the published documents and only a re-publish can
        # put them back, so say exactly that rather than reporting success.
        print(
            f"darklaunch: WARNING {station_id} has a pre-payload declaration — its rows were NOT "
            f"restored. Re-run: darklaunch-station.py publish {station_id} --rig DIR --like STATION"
        )
    return 0


def build_entry_from_sibling(manifest_path: Path, station_id: str, like: str, display_name: str | None) -> dict:
    manifest = load(manifest_path)
    sibling = next((e for e in manifest["entries"] if e.get("id") == like), None)
    if sibling is None:
        sys.exit(f"{manifest_path}: no entry with id {like!r} — --like must name a real station")
    entry = dict(sibling)
    entry["id"] = station_id
    entry["displayName"] = display_name or f"{station_id} (smoke rig)"
    entry["order"] = 900
    entry["listed"] = False
    entry["signalEndpoint"] = f"/signal/{station_id}.json"
    return entry


def cmd_publish(
    serve: Path,
    station_id: str,
    rig: Path,
    entry_file: Path | None,
    like: str | None,
    display_name: str | None,
    golden: dict | None = None,
) -> int:
    manifest_path = serve / "webroot" / "gallery-manifest.json"
    if entry_file is not None:
        entry = json.loads(entry_file.read_text())
    else:
        entry = build_entry_from_sibling(manifest_path, station_id, like, display_name)
    if entry.get("id") != station_id:
        sys.exit(f"entry id is {entry.get('id')!r}, expected {station_id!r}")
    entry["listed"] = False
    entry.setdefault("signalEndpoint", f"/signal/{station_id}.json")
    if not isinstance(entry.get("order"), int) or entry["order"] < 900:
        sys.exit("manifest entry needs an integer order >= 900 (parked above the real lineup)")

    tiles_path = serve / "tiles.json"
    tiles = load(tiles_path)
    manifest = load(manifest_path)
    tiles[station_id] = read_signaling(rig, station_id)
    manifest["entries"] = [e for e in manifest["entries"] if e.get("id") != station_id] + [entry]
    manifest["entries"].sort(key=lambda e: e.get("order", 0))
    write_json(tiles_path, tiles)
    write_json(manifest_path, manifest)
    golden_path = serve / "golden-manifest.json"
    if golden or had_golden_overlay(serve, station_id):
        golden_doc = load(golden_path)
        if golden:
            golden_doc.setdefault("tiles", {})[station_id] = golden
        else:  # re-published without --reset: take back the row the last one added
            golden_doc.get("tiles", {}).pop(station_id, None)
        write_json(golden_path, golden_doc)
    write_declaration(serve, station_id, True, tiles[station_id], entry, golden)
    print(f"published {station_id}: udp {tiles[station_id]['udpPort']}  /os/{station_id}")
    if golden:
        print(f"restore {station_id}: POST /restore/{station_id} -> reset-tile.sh on {golden['stationPath']}")
    return 0


def cmd_withdraw(serve: Path, station_id: str) -> int:
    tiles_path = serve / "tiles.json"
    manifest_path = serve / "webroot" / "gallery-manifest.json"
    tiles = load(tiles_path)
    manifest = load(manifest_path)
    had = tiles.pop(station_id, None) is not None
    before = len(manifest["entries"])
    manifest["entries"] = [e for e in manifest["entries"] if e.get("id") != station_id]
    write_json(tiles_path, tiles)
    write_json(manifest_path, manifest)
    golden_path = serve / "golden-manifest.json"
    if golden_path.is_file() and had_golden_overlay(serve, station_id):
        golden_doc = load(golden_path)
        golden_doc.get("tiles", {}).pop(station_id, None)
        write_json(golden_path, golden_doc)
    write_declaration(serve, station_id, False)
    removed = before - len(manifest["entries"])
    print(f"withdrew {station_id}: signal-row={'yes' if had else 'no'} manifest-entries={removed}")
    print("the rig itself is untouched")
    return 0


def cmd_status(serve: Path, station_id: str, rig: Path | None) -> int:
    tiles = load(serve / "tiles.json")
    manifest = load(serve / "webroot" / "gallery-manifest.json")
    entry = next((e for e in manifest["entries"] if e.get("id") == station_id), None)
    golden_path = serve / "golden-manifest.json"
    golden = json.loads(golden_path.read_text()).get("tiles", {}) if golden_path.is_file() else {}
    print(
        f"{station_id}: signal-row={'yes' if station_id in tiles else 'NO'} "
        f"manifest={'yes' if entry else 'NO'} listed={entry.get('listed') if entry else '-'} "
        f"restore={'yes' if station_id in golden else 'NO'} "
        f"declaration={'present' if decl_path(serve, station_id).is_file() else 'absent'}"
        + (f" rig-signaling={'present' if (rig / 'signaling.json').is_file() else 'ABSENT'}" if rig else "")
    )
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("publish", "withdraw", "status", "reapply"))
    ap.add_argument("id", nargs="?", help="station id (not used by `reapply`)")
    ap.add_argument("--rig", type=Path)
    ap.add_argument("--entry", type=Path, help="manifest entry JSON (publish)")
    ap.add_argument("--like", help="sibling station id to derive the manifest entry from (publish)")
    ap.add_argument("--display-name", help="displayName for the derived entry (default: '<id> (smoke rig)')")
    ap.add_argument("--reset", action="store_true", help="also overlay a golden-manifest row (publish)")
    ap.add_argument("--reset-mode", default="relaunch", help="resetMode of that row (default relaunch)")
    ap.add_argument("--snapshot", help="snapshot name of that row (loadvm rigs)")
    ap.add_argument("--serve-root", default=SERVE_ROOT, type=Path)
    args = ap.parse_args()
    if args.command == "reapply":
        return cmd_reapply(args.serve_root)
    if not args.id or not ID_RE.match(args.id):
        sys.exit(f"bad station id {args.id!r}")
    if args.command == "publish":
        if not args.rig or not (args.entry or args.like):
            sys.exit("publish needs --rig DIR and either --entry FILE or --like STATION")
        golden = golden_row(args.rig, args.id, args.reset_mode, args.snapshot) if args.reset else None
        return cmd_publish(args.serve_root, args.id, args.rig, args.entry, args.like, args.display_name, golden)
    if args.command == "withdraw":
        return cmd_withdraw(args.serve_root, args.id)
    return cmd_status(args.serve_root, args.id, args.rig)


if __name__ == "__main__":
    sys.exit(main())
