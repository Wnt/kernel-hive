#!/usr/bin/env python3
"""Name the guest code behind a slowrig.sh census window.

Input is the sampler log slow-agent.lua writes (`<emu_s> <pc> <entryhi>` per
line, hex). Output is a ranking of guest routines and of ASIDs -- i.e. which
IRIX process and which routine the emulator was executing while the window was
open.

The symbol table is the one the guest-pchist campaign pulled out of the guest
over FTP (`images.json`: exec ranges + FUNC symbols for the kernel and every
shared object). It is read-only here; this script does not rebuild it.

CAVEAT, stated because it bounds every conclusion drawn from the output: the
Lua periodic fires a few tens of times a second, so a window yields hundreds of
samples, not the 5 kHz of an instrumented build. That is enough to say "this
window is 80% kernel in ASID 3" and not enough to attribute single routines at
the percent level. Ranks below a few percent are noise.

  pcrank.py <pc-log> [top]
"""

import bisect
import json
import os
import sys
from collections import Counter

IMAGES = os.environ.get("IRIX_PC_IMAGES", "/data/vms/soltest/guest-pchist/images.json")


PREFIXES = ("n32:", "o32:", "_usr_sbin_", "_usr_bin_X11_", "_sbin_", "_usr_bin_")


def pretty(name):
    for a in PREFIXES:
        name = name.replace(a, "")
    name = name.replace(".so.1", "").replace(".so", "")
    return "kernel" if name == "unix" else name


def load_images():
    with open(IMAGES, encoding="utf-8") as fh:
        imgs = json.load(fh)
    spans = []
    for key, v in imgs.items():
        for lo, hi in v["ranges"]:
            spans.append((lo, hi, key))
    spans.sort()
    return imgs, spans, [s[0] for s in spans]


def resolve(imgs, spans, los, pc):
    i = bisect.bisect_right(los, pc)
    for j in range(max(0, i - 60), i):
        lo, hi, key = spans[j]
        if lo <= pc < hi:
            addrs = imgs[key]["addrs"]
            k = bisect.bisect_right(addrs, pc) - 1
            sym = imgs[key]["names"][k] if k >= 0 else "?"
            return pretty(key), sym
    return "?", f"{pc:08x}"


def main() -> int:
    path = sys.argv[1]
    top = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    imgs, spans, los = load_images()
    routines, asids, images = Counter(), Counter(), Counter()
    n = 0
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            f = line.split()
            if len(f) < 3:
                continue
            try:
                pc, hi = int(f[1], 16), int(f[2], 16)
            except ValueError:
                continue
            img, sym = resolve(imgs, spans, los, pc & 0xFFFFFFFF)
            routines[(img, sym)] += 1
            images[img] += 1
            asids[hi & 0xFF] += 1
            n += 1
    if not n:
        print("no samples in", path)
        return 1
    print(f"{os.path.basename(path)}: {n} samples")
    print("-- by image")
    for img, c in images.most_common(10):
        print(f"   {img:<24}{100.0 * c / n:7.2f}%")
    print("-- by ASID (EntryHi low byte)")
    for a, c in asids.most_common(10):
        print(f"   asid {a:<19}{100.0 * c / n:7.2f}%")
    print("-- by routine")
    for (img, sym), c in routines.most_common(top):
        print(f"   {img:<16}{sym:<34}{100.0 * c / n:7.2f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
