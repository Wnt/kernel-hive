#!/usr/bin/env python3
"""Assemble a MAME rompath from sha1-pinned staged blobs, listxml-driven.

The armeval/kc854 builders' lesson, generalized for the conversion campaign:
MAME renames romset MEMBERS between versions, so the only stable identity a
staged preservation blob has is its hash. This tool asks THE BINARY THAT WILL
RUN what members each set wants (-listxml), matches staged files to members
by sha1, and installs them as loose files under <outdir>/<set>/<member-name>.

Members with no matching staged blob are LISTED, not fatal: optional BIOS
variants are expected misses, and the boot gate (a framebuffer proof) is the
authority on whether the machine actually runs.

usage: stage-romset.py <binary> <machine> <staging-dir> <outdir> <set> [...]
"""

import hashlib
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 6:
        sys.exit(__doc__)
    binary, machine, staging, outdir = sys.argv[1:5]
    sets = sys.argv[5:]

    by_sha1 = {}
    for f in Path(staging).iterdir():
        if f.is_file():
            by_sha1[hashlib.sha1(f.read_bytes()).hexdigest()] = f

    xml = subprocess.run([binary, "-listxml", machine], capture_output=True, text=True, check=True).stdout
    root = ET.fromstring(xml)
    machines = {m.get("name"): m for m in root.findall("machine")}

    installed, missing = 0, []
    for set_name in sets:
        m = machines.get(set_name)
        if m is None:
            sys.exit(f"{binary}: -listxml {machine} does not describe set {set_name!r}")
        dest = Path(outdir) / set_name
        dest.mkdir(parents=True, exist_ok=True)
        for rom in m.findall("rom"):
            name, sha1 = rom.get("name"), rom.get("sha1")
            if not name or not sha1:
                continue
            src = by_sha1.get(sha1)
            if src is None:
                missing.append(f"  {set_name}/{name} sha1={sha1}")
                continue
            shutil.copyfile(src, dest / name)
            installed += 1
    print(f"stage-romset: {installed} member(s) installed under {outdir}")
    if missing:
        print(
            f"stage-romset: {len(missing)} member(s) have no staged blob "
            "(optional BIOS variants are expected here; the boot gate decides):"
        )
        print("\n".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
