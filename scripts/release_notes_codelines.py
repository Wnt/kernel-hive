#!/usr/bin/env python3
"""Added lines of hand-written SOURCE in a week — the repo's own definition of
a source file (check-file-size.mjs), so docs, markdown, JSON/registry data,
generated artifacts, vendored trees and lockfiles are all out.

The ROOT commit is skipped: it is the whole codebase arriving at once when the
repo was published, which was written earlier and is already counted in the
pre-public week. Counting it again would report the publication as the biggest
week of work in the project's history.
"""

import re
import subprocess
import sys

EXCL = re.compile(r"(^|/)(node_modules|third_party|dist|build)/|(^|/)package-lock\.json$")
GENERATED = {
    "streamhost/stations-manifest.sh",
    "streamhost/bring-up-all.sh",
    "scripts/build-guests/build-all.sh",
    "spa/src/three/archetypeRegistry.ts",
    "spa/src/data/posterIndex.ts",
    "spa/src/data/demoPrograms.ts",
    "spa/src/data/keyboards.ts",
}
EXTS = (".ts", ".tsx", ".js", ".jsx", ".rs", ".py", ".sh", ".c", ".h", ".cpp", ".patch")


def is_source(p):
    return not EXCL.search(p) and p not in GENERATED and (p.endswith(EXTS) or p.endswith("scripts/labctl"))


def count(repo, since, until, skip=()):
    out = subprocess.run(
        ["git", "-C", repo, "log", "--no-merges", "--numstat", "--format=%H", f"--since={since}", f"--until={until}"],
        capture_output=True,
        text=True,
    ).stdout
    added, current = 0, None
    for line in out.splitlines():
        if re.fullmatch(r"[0-9a-f]{40}", line):
            current = line
            continue
        parts = line.split("\t")
        if len(parts) == 3 and parts[0].isdigit() and current not in skip and is_source(parts[2]):
            added += int(parts[0])
    return added


def root_commits(repo):
    """The repo's root commit(s) — the whole codebase arriving at once."""
    out = subprocess.run(
        ["git", "-C", repo, "rev-list", "--max-parents=0", "HEAD"], capture_output=True, text=True
    ).stdout
    return set(out.split())


def for_window(repo, since, until):
    """The number the brief prints and the author copies into `codeLines`."""
    return count(repo, since, until, root_commits(repo))


if __name__ == "__main__":
    print(for_window(sys.argv[1], sys.argv[2], sys.argv[3]))
