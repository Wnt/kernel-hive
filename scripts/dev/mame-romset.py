#!/usr/bin/env python3
"""Assemble a MAME romset for ONE driver, by SHA1, from an archive.org reservoir.

WHY THIS EXISTS
---------------
The lab's MAME tiles each pin a purpose-built subtarget (0.289 today; the host
carries 0.276), but the practical source of romsets is a bulk archive.org dump
of a much older MAME -- 0.224 (2020) is the one with the best coverage. YOU
CANNOT FEED THOSE ZIPS STRAIGHT TO A NEWER MAME, and the failures are quiet:

  * MAME RENAMES MEMBERS between versions. kim1's `6530-002.bin` became
    `6530-002.u2`. A newer MAME looks for the new name, does not find it, and
    reports the set bad even though the bytes are present and correct.
  * MAME MOVES PARENT/CLONE SPLITS. kc85_4 was a kc85_2 clone in 0.251 and is
    its own parent in 0.276, where it needs `basic_c0.854` -- a member that only
    ever lived in the parent's zip.
  * `-verifyroms` IS NOT A USABLE GATE for computer drivers. It reports "bad"
    purely because ALTERNATIVE BIOS entries are absent (spectrum has ~30
    third-party ROMs, zx81 and ql several each), so a perfectly good set fails.
    And on dragon32 it points the WRONG WAY: with no slot options the driver
    boots DRAGONDOS rather than Microsoft BASIC, and verifyroms DEMANDS the FDC
    ROM that causes it.

So the only reliable identity is the SHA1. This tool asks the MAME YOU WILL
ACTUALLY SHIP what it wants, indexes every member of every candidate zip by
SHA1 regardless of filename, and writes a fresh zip with the members under the
names that MAME expects.

USAGE
    scripts/dev/mame-romset.py --driver kim1 --mame /usr/games/mame --out /tmp/roms
    scripts/dev/mame-romset.py --driver kc85_4 --mame ... --out ... --also kc85_2
    scripts/dev/mame-romset.py --driver ql --mame ... --out ... --bios js

`--also` adds extra reservoir zips to the SHA1 index (use it when a member
migrated between parents). Device sets named by -listxml are fetched
automatically. Nothing is committed: the bits stay wherever --out points, and
only the URL + measured sha256 belong in docs/lab/ASSETS-MANIFEST.md.
"""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

DEFAULT_ITEM = "MAME_0.224_ROMs_merged"
BASE = "https://archive.org/download"


def listxml(mame: str, driver: str) -> ET.Element:
    """Ask the SHIPPED MAME what this driver needs. Never guess from a wiki."""
    proc = subprocess.run([mame, "-listxml", driver], capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        sys.exit(f"mame -listxml {driver} failed: {proc.stderr.strip()[:200]}")
    return ET.fromstring(proc.stdout)


def wanted_roms(root: ET.Element, driver: str, bios: str | None) -> tuple[dict[str, str], dict[str, str], list[str]]:
    """-> (required, optional, device names).

    REQUIRED is the driver's OWN romset and nothing else. `-listxml <driver>`
    also emits every machine reachable through the driver's SLOTS, and those
    are not mandatory: a bare kim1 pulled in an Apple II Mockingboard, a
    Scorpion and four Sun keyboards, none of which the machine needs to boot.
    Treating them as required made a perfectly good set look 10/14. Device
    romsets are collected as OPTIONAL: fetched and included when the reservoir
    has them, reported when it does not, never fatal.

    Skips nodump entries (ql's hal16l8 has never been dumped and the machine
    runs) and, unless it is the selected bios, every alternative-bios entry --
    those are exactly what make -verifyroms lie about a good set.
    """
    required: dict[str, str] = {}
    optional: dict[str, str] = {}
    devices: list[str] = []
    for machine in root.iter("machine"):
        name = machine.get("name")
        is_target = name == driver
        if not is_target:
            devices.append(name)
        sink = required if is_target else optional
        for rom in machine.iter("rom"):
            sha1 = rom.get("sha1")
            if not sha1 or rom.get("status") == "nodump":
                continue
            rb = rom.get("bios")
            if is_target and rb and bios and rb != bios:
                continue
            sink[rom.get("name")] = sha1.lower()
    return required, optional, devices


def fetch(item: str, zipname: str, cache: Path) -> Path | None:
    dest = cache / zipname
    if dest.exists():
        return dest
    url = f"{BASE}/{item}/{zipname}"
    try:
        with urllib.request.urlopen(url, timeout=120) as resp, open(dest, "wb") as out:
            while chunk := resp.read(1 << 20):
                out.write(chunk)
    except Exception as exc:  # noqa: BLE001 - any failure just means "not in this reservoir"
        dest.unlink(missing_ok=True)
        print(f"  miss {zipname}: {exc}")
        return None
    print(f"  got  {zipname} ({dest.stat().st_size} B)")
    return dest


def index_by_sha1(paths: list[Path]) -> dict[str, tuple[Path, str]]:
    """Every member of every candidate zip, keyed by SHA1 -- NOT by filename,
    which is the whole point."""
    index: dict[str, tuple[Path, str]] = {}
    for path in paths:
        try:
            with zipfile.ZipFile(path) as zf:
                for member in zf.namelist():
                    if member.endswith("/"):
                        continue
                    digest = hashlib.sha1(zf.read(member)).hexdigest()
                    index.setdefault(digest, (path, member))
        except zipfile.BadZipFile:
            print(f"  bad zip, skipped: {path.name}")
    return index


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--driver", required=True)
    ap.add_argument("--mame", required=True, help="the MAME binary you will SHIP, not whatever is on PATH")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--item", default=DEFAULT_ITEM, help=f"archive.org item (default {DEFAULT_ITEM})")
    ap.add_argument("--also", action="append", default=[], help="extra reservoir zip stems to index")
    ap.add_argument("--bios", default=None, help="bios set to pin (default: the driver's own default)")
    ap.add_argument("--cache", type=Path, default=None)
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    cache = args.cache or (args.out / ".reservoir")
    cache.mkdir(parents=True, exist_ok=True)

    root = listxml(args.mame, args.driver)
    machine = next((m for m in root.iter("machine") if m.get("name") == args.driver), None)
    if machine is None:
        return print(f"{args.driver}: no such driver in this MAME") or 2
    bios = args.bios
    if bios is None:
        default = next((b.get("name") for b in machine.iter("biosset") if b.get("default") == "yes"), None)
        bios = default
    roms, optional, devices = wanted_roms(root, args.driver, bios)
    print(
        f"{args.driver}: {len(roms)} required (bios={bios or 'n/a'}), "
        f"{len(optional)} optional device members, {len(devices)} device sets"
    )

    stems = [args.driver, machine.get("cloneof"), machine.get("romof"), *devices, *args.also]
    candidates = [p for stem in dict.fromkeys(s for s in stems if s) if (p := fetch(args.item, f"{stem}.zip", cache))]
    if not candidates:
        return print("nothing fetched -- is the driver in this reservoir?") or 1

    index = index_by_sha1(candidates)
    out_zip = args.out / f"{args.driver}.zip"
    missing = []
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, sha1 in sorted(roms.items()):
            hit = index.get(sha1)
            if hit is None:
                missing.append((name, sha1))
                continue
            src, member = hit
            with zipfile.ZipFile(src) as srczip:
                zf.writestr(name, srczip.read(member))

    got = len(roms) - len(missing)
    print(f"wrote {out_zip} -- {got}/{len(roms)} members by sha1")
    for name, sha1 in missing:
        print(f"  MISSING {name} sha1={sha1}")
    if missing:
        print("\nA miss usually means the member migrated between parent sets in a newer")
        print("MAME. Re-run with --also <other-parent>, or try a newer reservoir item.")
        return 1
    digest = hashlib.sha256(out_zip.read_bytes()).hexdigest()
    print(f"sha256 {digest}  ({out_zip.stat().st_size} B)")
    print("Record URL + this sha256 + a licence class in docs/lab/ASSETS-MANIFEST.md.")
    print("NEVER commit the bits: the repo is public.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
