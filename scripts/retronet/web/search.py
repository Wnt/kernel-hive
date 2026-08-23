#!/usr/bin/env python3
"""retronet-search — the period search engine for the offline retronet web.

One stdlib process, no dependencies, meant to run INSIDE the gateway CT (951) on
``127.0.0.1:8090``. The corpus-only proxy (stream W1) routes a reserved hostname
(``search.retronet``) here; this service never speaks to anything but the local
corpus on disk. It answers three things, all as period HTML an era browser
renders:

  /            AltaVista-style front page (a query box)
  /search?q=   AltaVista-style ranked results, each linking to a corpus URL
  /dir         Yahoo!-style directory of every host the corpus can serve

The index is built in memory at start and rebuilt on demand — ``GET /reindex``,
``systemctl reload retronet-search`` (SIGHUP) or the reindex timer — so a fresh
corpus push by W2 is picked up without a restart.

Config comes from the environment (systemd EnvironmentFile
``/etc/retronet/search.env``); see ``install-search.sh``. Run modes:

  search.py serve      run the HTTP service (default)
  search.py index      build the index once, print stats, exit
  search.py reindex    conditional reindex for the timer: rebuild + refresh the
                       directory ONLY if the corpus fingerprint changed, else skip
  search.py selftest   build over the bundled fixture, assert, exit
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

import rn_render
from rn_index import Index, build_index, search

HERE = os.path.dirname(os.path.abspath(__file__))


@dataclass
class Config:
    host: str = "127.0.0.1"
    port: int = 8090
    corpus: str = "/data/retronet/corpus"
    sites: str = ""  # defaults to <corpus>/sites.json
    per_page: int = 10
    snippet: int = 160

    @classmethod
    def from_env(cls) -> Config:
        corpus = os.environ.get("RN_SEARCH_CORPUS", cls.corpus)
        return cls(
            host=os.environ.get("RN_SEARCH_HOST", cls.host),
            port=_int_env("RN_SEARCH_PORT", cls.port),
            corpus=corpus,
            sites=os.environ.get("RN_SEARCH_SITES", os.path.join(corpus, "sites.json")),
            per_page=_int_env("RN_SEARCH_PER_PAGE", cls.per_page),
            snippet=_int_env("RN_SEARCH_SNIPPET", cls.snippet),
        )


def _int_env(key: str, default: int) -> int:
    try:
        return int(os.environ.get(key, str(default)))
    except ValueError:
        return default


def load_sites(path: str) -> list[dict]:
    """Every site the corpus can actually serve, as directory rows.

    The manifest (``sites.json``, owned by era-press) supplies the titles, blurbs and
    categories for the curated set, but it is NOT the gate: the directory lists **every host
    with a home page on disk**, manifest entry or not. A host that was mirrored only because
    something linked to it is just as browsable as a curated one, and hiding it would
    advertise less of the retronet than exists. Hosts the manifest names but the corpus does
    not hold are dropped for the same reason -- a directory entry that cannot be opened is
    worse than no entry.

    The manifest is read tolerantly (it may be absent, a bare array, or ``{"sites": [...]}``);
    anything unparseable just means an untitled directory, never a crash.
    """
    try:
        with open(path, "rb") as fh:
            data = json.loads(fh.read().decode("utf-8", "replace"))
    except (OSError, ValueError):
        data = []
    if isinstance(data, dict):
        data = data.get("sites", [])
    named = {s["host"]: s for s in data if isinstance(s, dict) and s.get("host")} if isinstance(data, list) else {}

    corpus = os.path.dirname(path) or "."
    rows = []
    try:
        entries = sorted(os.scandir(corpus), key=lambda e: e.name)
    except OSError:
        entries = []
    for entry in entries:
        if not entry.is_dir(follow_symlinks=False):
            continue
        if not os.path.isfile(os.path.join(entry.path, "index.html")):
            continue  # no home page -> nothing a directory link could open
        row = dict(named.get(entry.name) or {})
        row["host"] = entry.name
        row.setdefault("title", entry.name)
        rows.append(row)
    return rows


class State:
    """The live index behind a lock, swapped atomically on a rebuild."""

    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self._lock = threading.Lock()
        self._index: Index = Index(corpus_root=cfg.corpus)

    @property
    def index(self) -> Index:
        with self._lock:
            return self._index

    def reindex(self) -> int:
        idx = build_index(self.cfg.corpus)
        with self._lock:
            self._index = idx
        return idx.n_docs


STATE: State | None = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # era-friendly; one request per connection
    server_version = "retronet-search/1.0"

    # --- routing ------------------------------------------------------------
    def do_GET(self) -> None:
        self._route(head_only=False)

    def do_HEAD(self) -> None:
        self._route(head_only=True)

    def _route(self, head_only: bool) -> None:
        assert STATE is not None
        split = urlsplit(self.path)  # tolerates absolute-form (proxy) and origin-form
        path = split.path or "/"
        params = parse_qs(split.query, keep_blank_values=True)

        if path in ("/", "/index.html"):
            self._html(rn_render.home_page(), head_only)
        elif path == "/search":
            self._search(params, head_only)
        elif path in ("/dir", "/directory", "/dir.html"):
            sites = load_sites(STATE.cfg.sites)
            self._html(rn_render.directory_page(sites), head_only)
        elif path == "/reindex":
            n = STATE.reindex()
            body = rn_render.text_page(
                "retronet-search: reindex",
                f"Index rebuilt from {STATE.cfg.corpus}: {n} document(s) now indexed.",
            )
            self._html(body, head_only)
        elif path == "/health":
            self._text(f"OK {STATE.index.n_docs} docs\n", head_only)
        elif path == "/favicon.ico":
            self._not_found(head_only, quiet=True)
        else:
            self._not_found(head_only)

    def _search(self, params: dict[str, list[str]], head_only: bool) -> None:
        assert STATE is not None
        query = (params.get("q") or [""])[0]
        try:
            page_no = max(1, int((params.get("pg") or ["1"])[0]))
        except ValueError:
            page_no = 1
        hits = search(STATE.index, query, STATE.cfg.snippet) if query.strip() else []
        body = rn_render.results_page(query, hits, page_no, STATE.cfg.per_page)
        self._html(body, head_only)

    # --- responses ----------------------------------------------------------
    def _html(self, markup: str, head_only: bool, code: int = 200) -> None:
        self._send(rn_render.to_bytes(markup), "text/html", head_only, code)

    def _text(self, text: str, head_only: bool, code: int = 200) -> None:
        self._send(text.encode("latin-1", "replace"), "text/plain", head_only, code)

    def _not_found(self, head_only: bool, quiet: bool = False) -> None:
        if quiet:
            self._send(b"", "text/plain", head_only, 404)
            return
        body = rn_render.text_page(
            "AltaVista: Not Found",
            "That page is not part of the search service. Try a search or the directory.",
        )
        self._html(body, head_only, code=404)

    def _send(self, body: bytes, ctype: str, head_only: bool, code: int) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write(f"retronet-search {self.address_string()} - {fmt % args}\n")


def serve(cfg: Config) -> None:
    global STATE
    STATE = State(cfg)
    n = STATE.reindex()
    sys.stderr.write(f"retronet-search: indexed {n} document(s) from {cfg.corpus}\n")

    def _on_hup(_signum: int, _frame: object) -> None:
        # Rebuild off the signal thread so the handler returns immediately.
        threading.Thread(target=_hup_reindex, daemon=True).start()

    signal.signal(signal.SIGHUP, _on_hup)
    httpd = ThreadingHTTPServer((cfg.host, cfg.port), Handler)
    sys.stderr.write(f"retronet-search: listening on {cfg.host}:{cfg.port}\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


def _hup_reindex() -> None:
    if STATE is not None:
        n = STATE.reindex()
        sys.stderr.write(f"retronet-search: reindexed on SIGHUP, {n} document(s)\n")


# --- CLI --------------------------------------------------------------------


def cmd_index(cfg: Config) -> int:
    idx = build_index(cfg.corpus)
    print(f"corpus:  {cfg.corpus}")
    print(f"docs:    {idx.n_docs}")
    print(f"tokens:  {len(idx.postings)}")
    for doc in idx.docs[:20]:
        print(f"  - {doc.url}  ({doc.title[:60]})")
    return 0


# --- conditional reindex (the 15-minute reindex timer's target) -------------
#
# The timer fires often, but the corpus only changes while W2's crawl is actively
# writing. So the reindex is GATED on a cheap corpus fingerprint (file count +
# total bytes + newest mtime — sites.json included, since it lives under the
# corpus root): unchanged => skip (no re-walk, no churn once the crawl is idle);
# changed => SIGHUP the running service to rebuild the in-memory search index, and
# refresh the Yahoo directory (rendered live from the corpus). The fingerprint
# persists in the unit's StateDirectory so a change is seen across timer runs, and
# it re-fires until the reload actually happens.

RELOAD_UNIT = "retronet-search.service"


def corpus_fingerprint(corpus_root: str) -> dict:
    """A cheap signature of the corpus: file count, total bytes, newest mtime.

    One os.scandir walk; sites.json sits under the corpus root, so a newly-crawled
    site (new pages + a rewritten manifest) always moves the fingerprint.
    """
    files = total = 0
    newest = 0.0
    stack = [corpus_root] if corpus_root and os.path.isdir(corpus_root) else []
    while stack:
        try:
            with os.scandir(stack.pop()) as it:
                for entry in it:
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(entry.path)
                            continue
                        st = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    files += 1
                    total += st.st_size
                    newest = max(newest, st.st_mtime)
        except OSError:
            continue
    return {"files": files, "bytes": total, "mtime": round(newest, 3)}


def _fp_path(name: str = "corpus.fp") -> str:
    """Where the last-indexed fingerprint lives (systemd StateDirectory, overridable for tests)."""
    base = os.environ.get("RN_SEARCH_STATE") or os.environ.get("STATE_DIRECTORY") or "/var/lib/retronet-search"
    return os.path.join(base.split(":")[0], name)  # $STATE_DIRECTORY may be colon-separated


def _read_fp(path: str) -> dict:
    try:
        with open(path) as fh:
            got = json.load(fh)
        return got if isinstance(got, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_fp(path: str, fp: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(fp, fh)
    os.replace(tmp, path)


def _reload_index(unit: str = RELOAD_UNIT) -> bool:
    """SIGHUP the running search service via systemd (try-reload = a no-op if it is stopped)."""
    try:
        return subprocess.run(["systemctl", "try-reload-or-restart", unit], capture_output=True).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def cmd_reindex(cfg: Config) -> int:
    """Conditional reindex for the 15-minute timer: rebuild the index + refresh the directory ONLY
    when the corpus fingerprint changed; otherwise skip. Prints one line either way, so the journal
    shows plainly which cycles did real work."""
    fp = corpus_fingerprint(cfg.corpus)
    n_sites = len(load_sites(cfg.sites))
    path = _fp_path()
    old = _read_fp(path)
    if old == fp:
        print(
            f"reindex: corpus unchanged ({fp['files']} files, {fp['bytes']} bytes, "
            f"mtime {fp['mtime']}, {n_sites} sites) — skipping"
        )
        return 0
    if not _reload_index():
        # Leave the stored fingerprint alone so the next cycle retries, never silently skips.
        print(f"reindex: corpus changed but index reload FAILED — will retry ({fp['files']} files)")
        return 1
    _write_fp(path, fp)
    print(
        f"reindex: corpus changed (files {old.get('files', 0)}->{fp['files']}, "
        f"bytes {old.get('bytes', 0)}->{fp['bytes']}) — index reloaded, "
        f"directory regenerated from the corpus ({n_sites} servable sites)"
    )
    return 0


def cmd_selftest() -> int:
    """Build over the bundled fixture and assert the acceptance invariants."""
    fixture = os.path.join(HERE, "fixtures", "corpus")
    idx = build_index(fixture)
    assert idx.n_docs >= 3, f"fixture should index >=3 docs, got {idx.n_docs}"

    hits = search(idx, "modem", 160)
    assert hits, "expected hits for 'modem'"
    assert all(h.doc.url.startswith("http://") for h in hits), "hits must carry corpus URLs"

    body = rn_render.results_page("modem", hits, 1, 10)
    raw = rn_render.to_bytes(body)
    assert b"charset=iso-8859-1" in raw, "results must declare Latin-1"
    assert b"<script" not in raw.lower(), "results must contain no JavaScript"
    raw.decode("latin-1")  # must be valid Latin-1
    assert b"http://" in raw, "results must link to corpus pages"

    # +required / -excluded / "phrase"
    plus = search(idx, "+guestbook", 160)
    assert plus, "expected a hit for +guestbook"
    minus_all = {h.doc.url for h in search(idx, "web", 160)}
    minus_some = {h.doc.url for h in search(idx, "web -guestbook", 160)}
    assert minus_some <= minus_all and len(minus_some) < len(minus_all), "-term must remove docs"
    phrase = search(idx, '"under construction"', 160)
    assert phrase, 'expected a hit for the phrase "under construction"'

    sites = load_sites(os.path.join(fixture, "sites.json"))
    assert sites, "fixture sites.json should load"
    dir_raw = rn_render.to_bytes(rn_render.directory_page(sites))
    assert b"Yahoo" in dir_raw, "directory must be Yahoo-styled"
    assert b"charset=iso-8859-1" in dir_raw and b"<script" not in dir_raw.lower()
    dir_raw.decode("latin-1")
    for site in sites:
        assert site["host"].encode("latin-1") in dir_raw, f"directory must list {site['host']}"

    # /dir metadata: the ORIGINAL capture date (month-year) + the three corpus metrics render, uncluttered.
    assert rn_render._month_year("20000511104630") == "May 2000", "14-digit stamp -> month-year"
    assert rn_render._month_year("19970412") == "April 1997", "8-digit stamp -> month-year"
    assert rn_render._month_year("2026-08-22") == "August 2026", "legacy ISO added-date -> month-year"
    assert rn_render._month_year("2000") == "", "too-short stamp -> blank, never a crash"
    assert rn_render._fmt_size(3_200_000) == "3.2 MB" and rn_render._fmt_size(812_000) == "812 KB"
    meta_row = {"host": "www.sgi.com", "title": "SGI", "captured": "20000511104630"}
    meta_row.update(pages=42, depth=4, bytes=3_200_000)
    entry = rn_render._dir_entry(meta_row)
    assert "May 2000" in entry and "42 pages" in entry and "depth 4" in entry and "3.2 MB" in entry, entry
    assert "[added" not in entry, "the download-date badge is gone; the capture date replaces it"
    # a bare row (no metrics, e.g. a corpus host with no manifest entry) still renders without them.
    assert "&middot;" not in rn_render._dir_entry({"host": "x.example", "title": "X"})

    # The corpus, not the manifest, decides what the directory lists: a mirrored host with no
    # manifest row is still browsable and must appear; a manifest row with nothing on disk must
    # not, because a directory link that cannot be opened is worse than no link.
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "unlisted.example"))
        with open(os.path.join(tmp, "unlisted.example", "index.html"), "w") as fh:
            fh.write("<html><body>hi</body></html>")
        os.makedirs(os.path.join(tmp, "no-home.example"))  # a dir, but nothing to open
        with open(os.path.join(tmp, "sites.json"), "w") as fh:
            json.dump([{"host": "vanished.example", "title": "Gone"}, {"host": "no-home.example"}], fh)
        hosts = {r["host"] for r in load_sites(os.path.join(tmp, "sites.json"))}
        assert hosts == {"unlisted.example"}, f"corpus decides the directory, got {hosts}"

    # empty/absent corpus is tolerated
    empty = build_index(os.path.join(HERE, "fixtures", "does-not-exist"))
    assert empty.n_docs == 0 and not search(empty, "anything", 160)
    rn_render.to_bytes(rn_render.directory_page([]))  # empty directory renders

    # conditional-reindex fingerprint: sees the fixture, is stable when unchanged,
    # moves on a change, and is all-zero for an absent corpus.
    fp = corpus_fingerprint(fixture)
    assert fp["files"] >= 3 and fp["bytes"] > 0 and fp["mtime"] > 0, "fingerprint should see the fixture"
    assert corpus_fingerprint(fixture) == fp, "fingerprint must be stable on an unchanged corpus"
    assert corpus_fingerprint(os.path.join(HERE, "fixtures", "nope")) == {"files": 0, "bytes": 0, "mtime": 0.0}
    with tempfile.TemporaryDirectory() as td:
        base = corpus_fingerprint(td)
        os.makedirs(os.path.join(td, "h"))
        with open(os.path.join(td, "h", "index.html"), "w") as fh:
            fh.write("<title>x</title>hello")
        assert corpus_fingerprint(td) != base, "a new page must change the fingerprint"

    print("selftest OK: index, ranking, +/-/phrase, Latin-1, directory, empty-corpus, reindex-fingerprint")
    return 0


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "serve"
    if cmd in ("serve", "run"):
        serve(Config.from_env())
        return 0
    if cmd == "index":
        return cmd_index(Config.from_env())
    if cmd == "reindex":
        return cmd_reindex(Config.from_env())
    if cmd in ("selftest", "--selftest", "test"):
        return cmd_selftest()
    if cmd in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    sys.stderr.write(f"search.py: unknown command {cmd!r} (serve|index|reindex|selftest)\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
