"""Production LINE coverage: which lines of the shipped SPA ever ran.

NAMED linecov AND NOT coverage. scripts/serve is on sys.path for the serving
plane, so a module called `coverage.py` here shadows the PyPI `coverage`
package for every import in the process — including any that a dependency
makes. The obvious name is the one that breaks something far away.

WHAT THIS ANSWERS THAT analytics.py DOES NOT. The feature-reach plane counts
DECLARED probes, so its denominator is a catalogue somebody wrote by hand and
its resolution is "this feature". This plane's denominator is the compiler's:
every instrumented statement in every module, whether or not anyone thought to
declare it. A probe can only tell you about code somebody suspected; this tells
you about the code nobody thought about, which is where dead code actually
lives.

WHY ITS OWN STORE, AND NOT A FOURTH TABLE IN analytics.db. Three reasons, and
the first is enough on its own:

  1. SIZE. An analytics row is a name and an integer. A row here is two
     run-length line sets for one file, hundreds of bytes to a few kilobytes,
     and there is one per file per build per class per day. Sharing a database
     with the counters means the counter store's size is dominated by something
     that is not counters, and the 64 KiB body cap that keeps a forged counter
     batch small would have to be raised by a factor of sixteen FOR COUNTERS
     TOO to let a coverage payload in. A cap is only a cap where it is tight.
  2. LIFETIME. The counters are kept for two years because "has anyone used
     this since March" is asked across seasons. A line map is meaningless
     against a bundle it did not come from: line numbers move on the next
     commit. Coverage keyed by build EXPIRES with the build, and a store whose
     rows expire in weeks does not belong in the one whose whole value is that
     its rows do not.
  3. BLAST RADIUS. This plane is fed by an OPT-IN bundle nobody runs by
     default. If it is never armed, this file creates an empty database and
     costs nothing; the durable counters must not share a schema with something
     that experimental.

NO IDENTITIES, SAME AS analytics.py, AND ONE STEP FURTHER. No user id is
accepted, none is stored, and there is no session id either: coverage merges by
UNION, so a session identifier would buy nothing and would be the one field
capable of turning "which lines ran" into "what this visitor did". The tab also
throws the HIT COUNTS away before sending — how many times each branch ran is a
behavioural trace, and "did it run at all" is the whole question.

BUILD-KEYED, AND NEVER UNIONED ACROSS BUILDS. Statement line numbers only mean
something against the bundle that produced them. Merging two builds' maps would
silently report lines from an older file as covered in a newer one, which is
worse than having no data: it is confidently wrong in the direction of "keep
this code".
"""

from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from pathlib import Path

#: Build ids are the plugin's 12 hex chars; classes match the analytics plane.
BUILD_RE = re.compile(r"^[0-9a-f]{6,32}$")
FILE_RE = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
RLE_RE = re.compile(r"^[0-9a-z]+(\.[0-9a-z]+)*$")
CLASSES = ("human", "probe", "unknown")

#: One tab sends one payload per session and it carries the whole module graph,
#: so the cap is generous where the counter plane's is tight — and it is a
#: DIFFERENT cap for exactly that reason (see the module docstring).
BODY_MAX = 1024 * 1024
#: Files in one payload. This SPA has ~40 instrumented modules; 400 is room to
#: grow and still a bound.
MAX_FILES = 400
#: Longest run-length string accepted for one file's line set. A 4000-line file
#: with pathological alternation is still well inside this.
MAX_RLE = 8192
#: Distinct builds kept. Enough to compare the bundle now live against the one
#: before it; beyond that a map is archaeology against source that has moved.
MAX_BUILDS = 8
#: Days of per-day detail. Short on purpose: a line map dies with its build.
RETENTION_DAYS = 120

SCHEMA = """
CREATE TABLE IF NOT EXISTS covmap (
  build TEXT NOT NULL, file TEXT NOT NULL,
  lines TEXT NOT NULL, n INTEGER NOT NULL, firstAt TEXT NOT NULL,
  PRIMARY KEY (build, file)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS covhit (
  day TEXT NOT NULL, build TEXT NOT NULL, class TEXT NOT NULL, file TEXT NOT NULL,
  lines TEXT NOT NULL, n INTEGER NOT NULL,
  PRIMARY KEY (day, build, class, file)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS covbuild (
  build TEXT PRIMARY KEY, firstAt TEXT NOT NULL, lastAt TEXT NOT NULL,
  sessions INTEGER NOT NULL, seq INTEGER NOT NULL DEFAULT 0);
"""


def _day(ts: float | None = None) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(ts if ts is not None else time.time()))


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def decode_lines(rle: str) -> set[int]:
    """`gap.run.gap.run...` in base 36 -> the set of line numbers it names.

    Malformed input yields the empty set rather than raising: this is
    client-supplied, and one tab with a mangled string must not be able to make
    a route throw.
    """
    out: set[int] = set()
    if not rle or not RLE_RE.match(rle):
        return out
    parts = rle.split(".")
    if len(parts) % 2:
        return out
    prev = 0
    for i in range(0, len(parts), 2):
        try:
            gap = int(parts[i], 36)
            run = int(parts[i + 1], 36)
        except ValueError:
            return set()
        if gap < 1 or run < 1 or run > 100_000:
            return set()
        start = prev + gap
        out.update(range(start, start + run))
        prev = start + run - 1
        if len(out) > 100_000:
            return set()
    return out


def encode_lines(lines: set[int]) -> str:
    """The inverse of `decode_lines`; the merged set goes back on disk in the
    same form the tab sent, so there is one encoding in the system, not two."""
    parts: list[str] = []
    prev = 0
    ordered = sorted(lines)
    i = 0
    while i < len(ordered):
        start = ordered[i]
        run = 1
        while i + run < len(ordered) and ordered[i + run] == start + run:
            run += 1
        parts.append(_b36(start - prev))
        parts.append(_b36(run))
        prev = start + run - 1
        i += run
    return ".".join(parts)


def _b36(value: int) -> str:
    if value <= 0:
        return "0"
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    while value:
        value, rem = divmod(value, 36)
        out = digits[rem] + out
    return out


def _rle(value) -> str | None:
    """A well-formed run-length line set, or None. The EMPTY string is
    well-formed and means the empty set — which for the executed half is the
    single most interesting row this plane can carry: a module that shipped and
    never ran a line. Rejecting it as malformed drops exactly the finding."""
    if not isinstance(value, str) or len(value) > MAX_RLE:
        return None
    if value and not RLE_RE.match(value):
        return None
    return value


class CoverageStore:
    """Merged production line coverage. Safe from any thread."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self._lock = threading.RLock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(self.path), check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(SCHEMA)
        self._db.commit()

    # ---- intake ------------------------------------------------------------

    def record(self, payload: dict) -> int:
        """Merge one tab's map in. Returns how many files were accepted.

        Unrecognised files are dropped silently, as in analytics.py and for the
        same reason: a tab on a slightly older instrumented bundle still has
        valid evidence for the modules that did not move.
        """
        build = payload.get("build")
        if not isinstance(build, str) or not BUILD_RE.match(build):
            return 0
        klass = payload.get("class")
        klass = klass if klass in CLASSES else "unknown"
        files = payload.get("files")
        if not isinstance(files, list):
            return 0
        day, now = _day(), _now()
        taken = 0
        with self._lock:
            cur = self._db.cursor()
            for row in files[:MAX_FILES]:
                taken += self._fold_file(cur, day, now, build, klass, row)
            if taken:
                # `seq` and not `lastAt` decides which build is newest. Wall
                # clock here is second-granular, and two reports landing in the
                # same second is not a corner case — it is what a page reload
                # looks like. A tie in the ordering means "newest build" picks
                # one arbitrarily, which is the whole answer being wrong.
                cur.execute(
                    "INSERT INTO covbuild(build,firstAt,lastAt,sessions,seq) "
                    "VALUES(?,?,?,1,(SELECT IFNULL(MAX(seq),0)+1 FROM covbuild)) "
                    "ON CONFLICT(build) DO UPDATE SET lastAt=excluded.lastAt, "
                    "sessions=sessions+1, seq=excluded.seq",
                    (build, now, now),
                )
                self._db.commit()
                self._trim_builds(cur)
                self._db.commit()
        return taken

    def _fold_file(self, cur, day: str, now: str, build: str, klass: str, row) -> int:
        if not isinstance(row, dict):
            return 0
        name = row.get("f")
        if not isinstance(name, str) or not FILE_RE.match(name) or ".." in name:
            return 0
        every = _rle(row.get("a"))
        hit = _rle(row.get("h"))
        if every is None or hit is None:
            return 0
        all_lines = decode_lines(every)
        if not all_lines:
            return 0
        # The executed set is CLAMPED to the instrumented set. A tab claiming a
        # line the build never instrumented is either a mangled payload or a
        # forged one; either way the denominator is the build's, not the tab's.
        hit_lines = decode_lines(hit) & all_lines
        # The denominator is written once per (build, file) and never widened:
        # every tab on one build sees the same statement map, so a later
        # disagreement is noise, not news.
        cur.execute(
            "INSERT INTO covmap(build,file,lines,n,firstAt) VALUES(?,?,?,?,?) ON CONFLICT(build,file) DO NOTHING",
            (build, name, every, len(all_lines), now),
        )
        prev = cur.execute(
            "SELECT lines FROM covhit WHERE day=? AND build=? AND class=? AND file=?",
            (day, build, klass, name),
        ).fetchone()
        merged = (decode_lines(prev[0]) if prev else set()) | hit_lines
        cur.execute(
            "INSERT INTO covhit(day,build,class,file,lines,n) VALUES(?,?,?,?,?,?) "
            "ON CONFLICT(day,build,class,file) DO UPDATE SET lines=excluded.lines, n=excluded.n",
            (day, build, klass, name, encode_lines(merged), len(merged)),
        )
        return 1

    def _trim_builds(self, cur) -> None:
        """Keep only the MAX_BUILDS most recently seen. Unbounded build ids are
        the one way a client could grow this store without limit."""
        keep = [r[0] for r in cur.execute("SELECT build FROM covbuild ORDER BY seq DESC LIMIT ?", (MAX_BUILDS,))]
        if not keep:
            return
        marks = ",".join("?" * len(keep))
        for table in ("covmap", "covhit", "covbuild"):
            cur.execute(f"DELETE FROM {table} WHERE build NOT IN ({marks})", keep)  # noqa: S608 - fixed names

    # ---- reading -----------------------------------------------------------

    def report(self, days: int = 30, klass: str = "human", build: str | None = None) -> dict:
        """Per-file executed/instrumented line counts for ONE build.

        One build, never a union: line numbers move between bundles, and a
        merged map would report a line as covered because a DIFFERENT file once
        had a live line there. With no build named, the most recently reported
        one wins.
        """
        since = _day(time.time() - max(1, days) * 86400)
        with self._lock:
            cur = self._db.cursor()
            builds = [
                {"build": b, "firstAt": f, "lastAt": last, "sessions": n}
                for b, f, last, n in cur.execute("SELECT build,firstAt,lastAt,sessions FROM covbuild ORDER BY seq DESC")
            ]
            chosen = build or (builds[0]["build"] if builds else None)
            files: dict[str, dict] = {}
            if chosen:
                for name, every, n in cur.execute("SELECT file,lines,n FROM covmap WHERE build=?", (chosen,)):
                    files[name] = {"lines": n, "executed": 0, "never": every}
                for name, rle in cur.execute(
                    "SELECT file,lines FROM covhit WHERE build=? AND class=? AND day>=?",
                    (chosen, klass, since),
                ):
                    entry = files.get(name)
                    if not entry:
                        continue
                    entry["_hit"] = entry.get("_hit", set()) | decode_lines(rle)
            for entry in files.values():
                hit = entry.pop("_hit", set())
                entry["executed"] = len(hit)
                entry["never"] = encode_lines(decode_lines(entry["never"]) - hit)
                entry["pct"] = round(100.0 * entry["executed"] / entry["lines"], 1) if entry["lines"] else 0.0
        return {
            "window": {"days": days, "since": since, "class": klass, "build": chosen},
            "builds": builds,
            "files": files,
        }

    def prune(self, keep_days: int = RETENTION_DAYS) -> int:
        cutoff = _day(time.time() - keep_days * 86400)
        with self._lock:
            cur = self._db.cursor()
            cur.execute("DELETE FROM covhit WHERE day<?", (cutoff,))
            removed = cur.rowcount
            self._trim_builds(cur)
            self._db.commit()
        return removed

    def close(self) -> None:
        with self._lock:
            self._db.close()


# ---- HTTP glue -------------------------------------------------------------


def handle_post(handler, store: CoverageStore) -> None:
    """POST /coverage — one instrumented tab's line map, once, at pagehide."""
    from static_files import MIME

    obj, err = handler._read_json_body(BODY_MAX)
    if err:
        return handler._send(err[0], json.dumps({"error": err[1]}), MIME[".json"], cache=False)
    if not isinstance(obj, dict):
        return handler._send(400, json.dumps({"error": "expected an object"}), MIME[".json"], cache=False)
    taken = store.record(obj)
    return handler._send(200, json.dumps({"ok": True, "files": taken}), MIME[".json"], cache=False)


def serve_report(handler, store: CoverageStore, query: dict) -> None:
    """GET /coverage/report.json?days=30&class=human[&build=<id>].

    Open like /analytics/report.json: file names and line numbers of a public
    repository, and no identities at all.
    """
    from static_files import MIME

    try:
        days = max(1, min(3650, int((query.get("days") or ["30"])[0])))
    except (TypeError, ValueError):
        days = 30
    klass = (query.get("class") or ["human"])[0]
    klass = klass if klass in CLASSES else "human"
    build = (query.get("build") or [None])[0]
    if build is not None and not BUILD_RE.match(build):
        build = None
    return handler._send(200, json.dumps(store.report(days, klass, build)), MIME[".json"], cache=False)
