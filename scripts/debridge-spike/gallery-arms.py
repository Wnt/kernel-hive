#!/usr/bin/env python3
"""Publish / withdraw the two de-bridging spike arms in the DEPLOYED gallery.

WHY THIS EXISTS, AND WHY THE ARMS ARE NOT REGISTRY ENTRIES
----------------------------------------------------------
The operator wants to drive both arms by hand, side by side, in a browser on the
gallery's HTTPS origin. The obvious route -- give each arm a `registry/tiles/`
entry with a `listing: hidden` soft hide -- does not work, and the reason is
structural rather than tedious:

  * `scripts/gen_tiles_json.py` (what `labctl gen` runs) hard-exits with
    "declared/live tile set mismatch" for ANY streamhost registry row that has no
    `/data/vms/streamhost/tiles/<tileDir>/` directory. Both arms live under
    `/data/vms/soltest/debridge-7f3a/`. So a registry row breaks `labctl gen` --
    and `tiles-registry.py --check` on the box, which compares the same sets --
    for every other session, until the arms are MOVED into the production tile
    directory and given a `tile.env` + `qemu-streamhost.sh`. Arm B has no QEMU
    launcher at all: it is host-native MAME.
  * the generated `scripts/serve/tiles.json` hardcodes each row's `hashFile` to
    `/data/vms/streamhost/tiles/<tileDir>/cert_hash_b64.txt`, so the registry has
    no way to say where these arms actually are.
  * `spa/src/data/tileWiring.test.ts` requires every streamhost manifest row to
    carry an exhibit poster, a scene identity, a machine assembly and a keyboard
    profile; `machines.test.ts` additionally requires a hardware signature
    DISTINCT from `atarist`'s. These arms are two instances of a machine that is
    already an exhibit, so all of that would be invented exhibit identity.

`listing: hidden` hides a row that BELONGS in the lineup. It is not a way to
admit a soltest rig into it. So the arms stay out of the registry, and this tool
carries the same SHAPE of divergence the soft hide produces -- the row exists and
`/os/<id>` resolves, `listed: false` keeps it out of the grid and the 3D hall --
as an explicit, committed, one-command-revertible deployment overlay owned by the
rig that created the arms.

It is additive and surgical: it touches ONLY the two `dbr-arm*` rows, exactly
like `scripts/serve/merge-serve-manifests.py`, so a sibling agent publishing a
real tile cannot be clobbered. The HTTPS server re-reads both documents per
request, so nothing needs restarting.

WHAT IT WRITES
    <serve>/tiles.json                      2 signaling rows (real soltest paths)
    <serve>/webroot/gallery-manifest.json   2 entries, both `"listed": false`
    <serve>/webroot/debridge-compare.html   the side-by-side page
    <serve>/darklaunch.d/debridge-arms.json the darklaunch declaration: it names
                                            exactly the rows added above, so
                                            scripts/dev/verify-box-sync.sh can
                                            verify the divergence is additive-only
                                            and report DARKLAUNCH (green) instead
                                            of DIFFERS (push-blocking)

REVERT (removes all four, leaves the arms running)
    ssh lab '/data/vms/soltest/debridge-7f3a/gallery-arms.py withdraw'

USAGE
    gallery-arms.py publish | withdraw | status [--serve-root DIR] [--rig DIR]

Run it ON THE BOX; the defaults are box paths.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

SERVE_ROOT = "/data/vms/streamhost/serve"
RIG_ROOT = "/data/vms/soltest/debridge-7f3a"
PAGE_NAME = "debridge-compare.html"

# order: parked far above the lineup so these can never collide with a real
# tile's binding order (the SPA rejects a manifest with duplicate orders).
ARMS = (
    {
        "dir": "armA",
        "id": "dbr-arma",
        "order": 900,
        "accent": "#e4002b",
        "displayName": "ST spike arm A — bridged",
        "eraLabel": "1985 · de-bridging spike arm A (bridged)",
        "blurb": "Spike arm A: the MAME Atari ST binary inside the Debian bridge kiosk (tier 2, the status quo).",
        "notes": "De-bridging spike arm, NOT an exhibit. Soft-hidden from the grid and the hall; "
        "reachable only at /os/dbr-arma. Published by scripts/debridge-spike/gallery-arms.py.",
    },
    {
        "dir": "armB",
        "id": "dbr-armb",
        "order": 901,
        "accent": "#00a3e0",
        "displayName": "ST spike arm B — host-native",
        "eraLabel": "1985 · de-bridging spike arm B (host-native)",
        "blurb": "Spike arm B: the same MAME Atari ST binary host-native, frames via drawshm (tier 3, the candidate).",
        "notes": "De-bridging spike arm, NOT an exhibit. Soft-hidden from the grid and the hall; "
        "reachable only at /os/dbr-armb. Published by scripts/debridge-spike/gallery-arms.py.",
    },
)
ARM_IDS = frozenset(arm["id"] for arm in ARMS)
DARKLAUNCH_NAME = "debridge-arms"


def darklaunch_path(serve: Path) -> Path:
    return serve / "darklaunch.d" / f"{DARKLAUNCH_NAME}.json"


def read_signaling(arm_dir: Path, arm: dict) -> dict:
    """The arm's own signaling.json is the authority for id and UDP port."""
    doc = json.loads((arm_dir / "signaling.json").read_text())
    tile = doc.get("tile")
    if tile != arm["id"]:
        sys.exit(f"{arm_dir}/signaling.json: tile is {tile!r}, expected {arm['id']!r} — wrong rig?")
    port = doc.get("udpPort")
    if not isinstance(port, int):
        sys.exit(f"{arm_dir}/signaling.json: no integer udpPort")
    hash_file = arm_dir / "cert_hash_b64.txt"
    if not hash_file.is_file():
        sys.exit(f"{hash_file}: absent — is the arm's streamhost running?")
    return {"udpPort": port, "hashFile": str(hash_file)}


def manifest_entry(arm: dict) -> dict:
    """A minimal but SPA-valid lineup row (spa/src/data/galleryManifest.ts).

    `listed: false` is the whole point: useManifest carries the row into the
    store so /os/<id> resolves, while the grid and the 3D hall read listedVms
    and never see it. Same field the registry soft hide emits.
    """
    return {
        "id": arm["id"],
        "era_year": 1985,
        "displayName": arm["displayName"],
        "year": 1985,
        "lineage": "Atari ST / Digital Research GEM",
        "arch": "Motorola 68000 (m68k)",
        "accent": arm["accent"],
        "archetypeId": "beige-tower-crt",
        "transport": "streamhost",
        "order": arm["order"],
        "eraLabel": arm["eraLabel"],
        "signalEndpoint": f"/signal/{arm['id']}.json",
        "listed": False,
        "notes": arm["notes"],
        "era": "1980s",
        "eraSoftware": ["GEM desktop (TOS)"],
        "periodBrowser": "none — pre-web 16-bit era",
        "iconicApps": ["GEM desktop (DISK A/B, TRASH, PRINTER)"],
        "blurb": arm["blurb"],
    }


def write_json(path: Path, doc: dict, indent: int) -> None:
    tmp = path.with_name(f".{path.name}.dbr-tmp")
    tmp.write_text(json.dumps(doc, indent=indent, ensure_ascii=False) + "\n")
    tmp.replace(path)


def load(path: Path) -> dict:
    if not path.is_file():
        sys.exit(f"{path}: not found — wrong --serve-root?")
    return json.loads(path.read_text())


def cmd_publish(serve: Path, rig: Path) -> int:
    tiles_path = serve / "tiles.json"
    manifest_path = serve / "webroot" / "gallery-manifest.json"
    tiles = load(tiles_path)
    manifest = load(manifest_path)

    rows = {}
    for arm in ARMS:
        rows[arm["id"]] = read_signaling(rig / arm["dir"], arm)

    for arm in ARMS:
        tiles[arm["id"]] = rows[arm["id"]]
        entry = manifest_entry(arm)
        manifest["entries"] = [e for e in manifest["entries"] if e.get("id") != arm["id"]]
        manifest["entries"].append(entry)
    manifest["entries"].sort(key=lambda e: e.get("order", 0))

    write_json(tiles_path, tiles, 2)
    write_json(manifest_path, manifest, 2)

    page_src = Path(__file__).resolve().parent / "compare.html"
    page_dst = serve / "webroot" / PAGE_NAME
    if page_src.is_file():
        shutil.copyfile(page_src, page_dst)
    else:
        print(f"warning: {page_src} absent — compare page not installed", file=sys.stderr)

    # The darklaunch declaration: the claim box-sync verifies instead of
    # blocking on. It must name EXACTLY the rows written above — nothing else
    # this overlay diverges by is forgiven by the gate.
    decl_path = darklaunch_path(serve)
    decl_path.parent.mkdir(parents=True, exist_ok=True)
    decl = {
        "darklaunch": DARKLAUNCH_NAME,
        "owner": str(Path(__file__).resolve()),
        "note": "de-bridging spike arms at /os/dbr-arma and /os/dbr-armb; revert with: gallery-arms.py withdraw",
        "files": {
            str(tiles_path): {"kind": "json-object-keys", "ids": sorted(ARM_IDS)},
            str(manifest_path): {"kind": "json-entries", "ids": sorted(ARM_IDS)},
        },
    }
    write_json(decl_path, decl, 2)

    for arm in ARMS:
        print(f"published {arm['id']}: udp {rows[arm['id']]['udpPort']}  /os/{arm['id']}")
    print(f"published {page_dst.name}")
    print(f"declared darklaunch: {decl_path}")
    return 0


def cmd_withdraw(serve: Path, _rig: Path) -> int:
    tiles_path = serve / "tiles.json"
    manifest_path = serve / "webroot" / "gallery-manifest.json"
    tiles = load(tiles_path)
    manifest = load(manifest_path)

    removed = sorted(ARM_IDS & set(tiles))
    for arm_id in ARM_IDS:
        tiles.pop(arm_id, None)
    before = len(manifest["entries"])
    manifest["entries"] = [e for e in manifest["entries"] if e.get("id") not in ARM_IDS]

    write_json(tiles_path, tiles, 2)
    write_json(manifest_path, manifest, 2)
    page = serve / "webroot" / PAGE_NAME
    page.unlink(missing_ok=True)
    decl = darklaunch_path(serve)
    decl.unlink(missing_ok=True)

    print(f"withdrew signaling rows: {removed or 'none'}")
    print(f"withdrew manifest entries: {before - len(manifest['entries'])}")
    print(f"removed {page}")
    print(f"removed {decl}")
    print("the arms themselves are untouched and still running")
    return 0


def cmd_status(serve: Path, rig: Path) -> int:
    tiles = load(serve / "tiles.json")
    manifest = load(serve / "webroot" / "gallery-manifest.json")
    listed = {e["id"]: e for e in manifest["entries"] if e.get("id") in ARM_IDS}
    for arm in ARMS:
        arm_id = arm["id"]
        sig = rig / arm["dir"] / "signaling.json"
        entry = listed.get(arm_id)
        print(
            f"{arm_id:<10} signal-row={'yes' if arm_id in tiles else 'NO ':<3} "
            f"manifest={'yes' if entry else 'NO '} listed={entry.get('listed') if entry else '-'} "
            f"arm-signaling={'present' if sig.is_file() else 'ABSENT'}"
        )
    print(f"compare page: {'present' if (serve / 'webroot' / PAGE_NAME).is_file() else 'absent'}")
    print(f"darklaunch declaration: {'present' if darklaunch_path(serve).is_file() else 'absent'}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("publish", "withdraw", "status"))
    ap.add_argument("--serve-root", default=SERVE_ROOT)
    ap.add_argument("--rig", default=RIG_ROOT)
    args = ap.parse_args()
    handler = {"publish": cmd_publish, "withdraw": cmd_withdraw, "status": cmd_status}[args.command]
    return handler(Path(args.serve_root), Path(args.rig))


if __name__ == "__main__":
    sys.exit(main())
