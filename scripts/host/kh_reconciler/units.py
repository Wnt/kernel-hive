"""Release units — the concurrency grain of convergence.

The whole design turns on one observation: **the unit of deployment is the
whole box, but the unit of work is one station.** Everything here re-cuts the
system along station lines so that N sessions "deploy" by pushing commits that
touch disjoint units, and the loop serializes per unit instead of per box.

Four kinds of unit:

* `station:<id>` — one per station: its launcher, its env fixture, its
  station-local scripts, its registry declaration. Binary and golden join in
  stage 4 when the closure store exists.
* `serve-code` — the SPA bundle and the serve-side Python. Dirty only when the
  COMMIT changes.
* `serve-manifests` — the rendered runtime documents; a pure function of
  applied station state. Split from serve-code deliberately: were manifests
  members of one serve closure, every station cutover would dirty it — 61 serve
  flips per wave, each republishing an unchanged bundle and each paying the
  serve unit's strictest disruption class.
* `host-tools` — guards, labctl, host scripts.

MEMBERSHIP IS REPO-SIDE AND OFFLINE. It is computed from tracked paths, so
`plan` and `status` work in a public clone with no box. When the box IS
reachable the live pair table is cross-checked against it, and a deployed row
that belongs to NO unit is reported: such a row would be converged by nobody,
forever — the "deployed-invisible" class the pair table's own tree loops exist
to prevent, one level up.
"""

from __future__ import annotations

import re
from pathlib import Path

from .denylist import filter_members

SERVE_CODE = (
    re.compile(r"^scripts/serve/"),
    re.compile(r"^spa/"),
)
HOST_TOOLS = (
    re.compile(r"^scripts/lib/"),
    re.compile(r"^scripts/host/"),
    re.compile(r"^scripts/labctl(\.d/|$)"),
    re.compile(r"^scripts/dev/"),
    # The observability carriers and their systemd units (kh-trace-ship,
    # kh-instana-forward). Box-wide, not per-station: one timer serves the whole
    # fleet's spans, so they belong with the other host tools rather than to any
    # station. Added when those units became deployed rows and this list was the
    # thing that noticed they belonged to nobody.
    re.compile(r"^scripts/observability/"),
    re.compile(r"^scripts/[^/]+\.(py|sh)$"),
)
# The daemon and its service template: built by the loop from the commit (7),
# with every station closure referencing the resulting object. Its SOURCE is one
# unit so that a daemon change is one dirty unit rather than 61.
DAEMON = (
    re.compile(r"^streamhost/streamhost/"),
    re.compile(r"^streamhost/Cargo\.(toml|lock)$"),
    re.compile(r"^streamhost/deploy/streamhost@\.service$"),
    re.compile(r"^streamhost/qemu-patches/"),
)
# Everything the rendered runtime documents are a function of: the registry
# sources AND the rendered outputs themselves.
SERVE_MANIFESTS = (
    re.compile(r"^registry/"),
    re.compile(r"^build/registry/"),
)
STATION_DIR = re.compile(r"^streamhost/stations/([^/]+)/")
STATION_DECL = re.compile(r"^registry/stations/([^/]+)\.json$")
# Per-station files that live OUTSIDE the station directory. Each of these
# families was found by cross-checking the live pair table against an earlier,
# narrower decomposition, which left 107 deployed rows claimed by no unit.
STATION_ELSEWHERE = (
    re.compile(r"^streamhost/guest-agents/([^/]+)/"),
    re.compile(r"^streamhost/deploy/streamhost@([^/.]+)\.service\.d/"),
)
# ...and families where the STATION NAME is a filename prefix, which can only be
# resolved against the real station list — a bare regex would claim
# `win98se-icq-nudge.py` for a station called `win98se-icq` just as happily.
STATION_PREFIXED = (
    re.compile(r"^scripts/retronet/(?P<rest>[^/]+)$"),
    re.compile(r"^scripts/coldboot/(?P<rest>[^/]+)$"),
    re.compile(r"^streamhost/deploy/(?P<rest>[^/]+)$"),
)


def station_in_filename(rest: str, stations: frozenset[str]) -> str | None:
    """The station a per-station filename names, or None.

    Two shapes occur in the live pair table and BOTH must work, which is only
    knowable by cross-checking against it: the id is usually a prefix
    (`win98se-icq-nudge.py`) but is sometimes a suffix
    (`seriald-sailfishos.service`). So the id is matched as a whole
    dash-delimited token, or as a prefix. Longest match wins, so `win2000` is
    never mistaken for `win2` and a two-part id is never split.

    Matched against the REAL station list, never a bare regex: a pattern would
    claim `win98se-icq-nudge.py` for a station called `win98se-icq` just as
    happily, and be wrong silently.
    """
    stem = rest.rsplit(".", 1)[0]
    tokens = set(re.split(r"[^A-Za-z0-9]+", stem))
    candidates = [s for s in stations if s in tokens or stem.startswith(s)]
    return max(candidates, key=len) if candidates else None


def unit_of(path: str, stations: frozenset[str] = frozenset()) -> str | None:
    """The single unit a repo path belongs to, or None if it ships with nothing.

    Order matters: the most SPECIFIC claim wins. A station's own files beat the
    broad serve/host globs, and the daemon's tree beats the station-prefixed
    filename families.
    """
    for rx in (STATION_DIR, STATION_DECL, *STATION_ELSEWHERE):
        m = rx.match(path)
        if m:
            return f"station:{m.group(1)}"
    for rx in DAEMON:
        if rx.match(path):
            return "streamhost-daemon"
    for rx in STATION_PREFIXED:
        m = rx.match(path)
        if not m:
            continue
        hit = station_in_filename(m.group("rest"), stations)
        if hit:
            return f"station:{hit}"
    for rx in SERVE_MANIFESTS:
        if rx.match(path):
            return "serve-manifests"
    for rx in SERVE_CODE:
        if rx.match(path):
            return "serve-code"
    for rx in HOST_TOOLS:
        if rx.match(path):
            return "host-tools"
    return None


def build_units(tracked: list[str], stations: frozenset[str] | None = None) -> dict[str, list[str]]:
    """unit -> its sorted members. Every member is proved not state of record."""
    if stations is None:
        stations = frozenset(station_ids(tracked))
    units: dict[str, list[str]] = {}
    for path in tracked:
        unit = unit_of(path, stations)
        if unit is None:
            continue
        units.setdefault(unit, []).append(path)
    return {u: filter_members(sorted(members)) for u, members in sorted(units.items())}


def unclaimed_live_rows(
    pair_rows: list[tuple[str, str]], stations: frozenset[str] = frozenset()
) -> list[tuple[str, str]]:
    """Deployed rows that belong to no unit — converged by nobody, forever.

    `pair_rows` is (label, repo-relative path) from the ONE pair table. A row
    here is not necessarily a bug: it may be a path this decomposition has not
    learned yet. It is always a QUESTION worth answering before the loop is
    allowed to write anything, which is why stage 3 reports it and stage 4
    depends on it being empty.
    """
    return [(label, path) for label, path in pair_rows if path and unit_of(path, stations) is None]


def station_ids(tracked: list[str]) -> list[str]:
    return sorted({m.group(1) for p in tracked if (m := STATION_DECL.match(p))})


def tracked_files(repo: Path, git) -> list[str]:
    out = git("ls-files", cwd=repo)
    return [line for line in out.splitlines() if line]
