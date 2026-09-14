#!/usr/bin/env python3
"""corpus-completeness -- score how much of each corpus landing page can actually DRAW.

WHY. A station's home page was picked for being iconic, and the corpus held a hollow
mirror of it: `spacejam.com`'s index meta-refreshes to a page whose entire navigation
bitmap (`img/nf-planets.gif`) was never mirrored, so two walk-in stations opened on a
near-black screen for weeks. Nothing reported it -- the page was HTTP 200, the site
directory existed, and only a human looking at the framebuffer could tell. `www.ibm.com`
(61% of its bitmaps), `home.microsoft.com` (43%), `www.mtv.com` (11%) fail the same way.

So this answers one question, per host: **of every bitmap the landing page asks for,
how many does the corpus actually hold?** Menus, banners, spacers, nav bars and
backgrounds are the ones that decide whether a page looks whole -- a missing hero
image is a blemish, a missing nav strip is a gutted page.

Assets are counted from `<img src>`, `<input type=image src>`, `background=` (body and
table cells), CSS `url(...)`, and `<embed src>`, on the landing page AND on each
document of a `<frameset>`. Ad-server misses are counted SEPARATELY and never held
against a site: a 1998 page with a dead doubleclick slot is period-correct, not broken.

It also reports what the page DEMANDS of a browser, because the corpus is served to
browsers that predate the features: IBM WebExplorer and OmniWeb 3 have no JavaScript,
so a nav built by `document.write` is invisible no matter how complete the mirror is.

usage:
  corpus-completeness.py [--root DIR] [--top N] [--min-assets N] [--json]
  corpus-completeness.py --host www.xerox.com [--host ...]

Run it where the corpus is -- inside CT 951, which is the only place it is mounted:
  ssh lab 'pct exec 951 -- python3 /tmp/corpus_completeness.py --top 40'
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

CORPUS_ROOT = "/data/retronet/corpus"
INDEX_NAMES = ("index.html", "index.htm", "index.cgi", "index.shtml", "default.html", "default.htm")

# A miss on one of these is a dead ad slot, which is how the period web looked anyway.
AD_HOST = re.compile(
    r"(doubleclick|akamai|admonitor|adforce|linkexchange|\bads?\.|adengine|adimages"
    r"|adremote|realmedia|flycast|netgravity|burstnet|valueclick|adserv)",
    re.I,
)
ASSET_PATTERNS = (
    r"<img[^>]+?src\s*=\s*[\"']?([^\"'>\s]+)",
    r"<input[^>]+?type\s*=\s*[\"']?image[\"']?[^>]*?src\s*=\s*[\"']?([^\"'>\s]+)",
    r"\bbackground\s*=\s*[\"']?([^\"'>\s]+)",
    r"url\(\s*[\"']?([^\"')\s]+)",
    r"<embed[^>]+?src\s*=\s*[\"']?([^\"'>\s]+)",
)
FRAME_SRC = r"<frame[^>]+?src\s*=\s*[\"']?([^\"'>\s]+)"
MAX_FRAMES = 8


def read_text(path):
    """Corpus bytes are original 1990s bytes -- never assume UTF-8, never fail on them."""
    try:
        with open(path, "rb") as handle:
            return handle.read().decode("latin-1")
    except OSError:
        return None


def landing_page(host_dir):
    for name in INDEX_NAMES:
        candidate = os.path.join(host_dir, name)
        if os.path.isfile(candidate):
            return candidate
    return None


def resolve(host, ref):
    """(host, path) for an asset reference, or None when it names nothing fetchable."""
    ref = ref.strip().replace("\\", "/")
    if ref.startswith("//"):
        ref = "http:" + ref
    if ref.lower().startswith(("mailto:", "javascript:", "data:", "#")):
        return None
    if ref.startswith("http"):
        match = re.match(r"https?://([^/]+)(/.*)?", ref)
        if not match:
            return None
        host, path = match.group(1), match.group(2) or "/"
    else:
        path = ref if ref.startswith("/") else "/" + ref
    return host, path.split("?")[0].split("#")[0]


def asset_refs(text):
    refs = []
    for pattern in ASSET_PATTERNS:
        refs += re.findall(pattern, text, re.I)
    return refs


def present(root, host, path):
    target = os.path.join(root, host, path.lstrip("/"))
    if os.path.isdir(target):
        target = os.path.join(target, "index.html")
    return os.path.isfile(target)


def demands(text):
    """What the page needs from a browser -- the part completeness alone will not tell you."""
    low = text.lower()
    depth = peak = 0
    for match in re.finditer(r"</?table", low):
        depth += -1 if low[match.start() : match.start() + 7].startswith("</") else 1
        peak = max(peak, depth)
    flags = []
    if "<frameset" in low:
        flags.append("frames")
    if "document.write" in low:
        flags.append("docwrite")  # invisible to WebExplorer and OmniWeb 3
    if "<script" in low:
        flags.append("js")
    if "<style" in low or "stylesheet" in low:
        flags.append("css")
    if "usemap" in low:
        flags.append("imagemap")
    if "<layer" in low:
        flags.append("layer")
    return flags, peak


def score_host(root, host):
    host_dir = os.path.join(root, host)
    index = landing_page(host_dir)
    if not index:
        return None
    text = read_text(index)
    if not text:
        return None

    pages = [(host, text)]
    frames = re.findall(FRAME_SRC, text, re.I)
    for ref in frames[:MAX_FRAMES]:
        target = resolve(host, ref)
        if not target:
            continue
        path = os.path.join(root, target[0], target[1].lstrip("/"))
        if os.path.isdir(path):
            path = os.path.join(path, "index.html")
        frame_text = read_text(path)
        if frame_text:
            pages.append((target[0], frame_text))

    total = broken = ads = 0
    missing = []
    for page_host, page_text in pages:
        for ref in asset_refs(page_text):
            target = resolve(page_host, ref)
            if not target:
                continue
            total += 1
            if present(root, *target):
                continue
            if AD_HOST.search(target[0] + target[1]):
                ads += 1
            elif len(missing) < 8:
                broken += 1
                missing.append(target[0] + target[1])
            else:
                broken += 1

    flags, table_depth = demands(text)
    title = re.search(r"<title[^>]*>(.*?)</title>", text, re.S | re.I)
    return {
        "host": host,
        "assets": total,
        "broken": broken,
        "ad_misses": ads,
        "complete_pct": round(100 * (1 - broken / total), 1) if total else 100.0,
        "frames": len(frames),
        "table_depth": table_depth,
        "demands": flags,
        "bytes": len(text),
        "title": (title.group(1).strip()[:52] if title else ""),
        "missing": missing,
    }


def scan(root, hosts=None):
    names = hosts or sorted(os.listdir(root))
    rows = []
    for host in names:
        if not os.path.isdir(os.path.join(root, host)):
            continue
        row = score_host(root, host)
        if row:
            rows.append(row)
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(prog="corpus-completeness")
    parser.add_argument("--root", default=CORPUS_ROOT)
    parser.add_argument("--host", action="append", help="score only these hosts")
    parser.add_argument("--top", type=int, default=40)
    parser.add_argument("--min-assets", type=int, default=8, help="ignore near-empty landing pages")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    if not os.path.isdir(args.root):
        parser.error(f"no corpus at {args.root} (it is mounted only inside CT 951)")

    rows = scan(args.root, args.host)
    if not args.host:
        rows = [r for r in rows if r["assets"] >= args.min_assets]
    rows.sort(key=lambda r: (-r["complete_pct"], -r["assets"]))

    if args.json:
        json.dump(rows, sys.stdout, indent=1)
        return 0

    print(f"{'host':<30}{'whole':>7}{'bitmaps':>9}{'gone':>6}{'ads':>5}  demands")
    for row in rows[: args.top]:
        flags = ",".join(row["demands"]) or "plain html"
        depth = f" tables{row['table_depth']}" if row["table_depth"] > 2 else ""
        print(
            f"{row['host']:<30}{row['complete_pct']:6.1f}%{row['assets']:9}"
            f"{row['broken']:6}{row['ad_misses']:5}  {flags}{depth}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
