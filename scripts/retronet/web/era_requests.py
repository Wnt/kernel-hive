#!/usr/bin/env python3
"""era_requests -- what the retronet was ASKED for and could not answer.

A miss is the most honest signal this system produces. The disk scan that seeded
era-sites.json can only find URLs that happen to sit in a guest image as readable
text; it will always miss some, and it can never know which of them a visitor
actually walks to. A miss knows: a station asked, and the museum had nothing.

So the proxy journals every miss (`proxy.record_miss`) and this module turns that
journal into a priority queue the crawl services. ONE rule decides eligibility,
and it reads the same at every point in a URL's life:

    **Two asks, fifteen minutes apart, since the last decision.**

* **Two asks, not one.** A single request is noise -- a typo in the address bar, a
  probe, a broken image on a page nobody will revisit.
* **Fifteen minutes apart.** A burst is one visit; a real gap is a person or a
  station coming BACK to the same missing thing.
* **Since the last decision.** Every outcome moves a per-URL `gate`, and only asks
  after the gate count. That is what stops a URL from being retried forever: an
  archive.org verdict of "no capture" pushes the gate 30 DAYS out, and asks inside
  that window are pruned, not banked -- so when the window closes nothing fires by
  itself. The URL must earn its retry again, from scratch, with two fresh asks
  fifteen minutes apart. See RETRY_COOLDOWN and `mark_served`.
* **More requests, more priority.** `count` is every ask ever, and it orders the
  queue -- so a URL asked 40 times during its cooldown is not retried early, but it
  goes to the front the moment it does re-qualify.

Journalled misses live in a small SPOOL DIRECTORY that both containers mount --
NOT the corpus, which is deliberately read-only to the proxy (see WEB-PROXY.md).
The journal is rotated before reading, so the proxy can keep appending to a fresh
file while a batch is processed. See docs/lab/retronet/ERA-PRESS.md.
"""

from __future__ import annotations

import contextlib
import json
import os
import threading
import time

MISS_JOURNAL = "_requests.jsonl"  # written by proxy.record_miss into the shared spool dir
MIN_REQUESTS = 2  # asked for at least this many times...
MIN_SPREAD = 15 * 60  # ...spanning at least this long, so a single burst is not enough
SOURCE = "station request"  # what these entries are, in the state file and the log

# How long a URL archive.org has no in-ceiling capture for is left alone. It is deliberately long: the
# answer "the Wayback Machine has no pre-2001 capture of this" does not change week to week, and every
# retry is a request we make of someone else's infrastructure for a thing we already know is not there.
RETRY_COOLDOWN = 30 * 24 * 3600

# Per-URL ask timestamps we keep. Only the newest few can ever matter (eligibility needs 2 of them and a
# 15-minute spread), so the trailing window is capped and the state file stays small however long a
# station hammers a dead URL.
MAX_ASKS = 16

# What an outcome word from `Servicer.__call__` means for the gate.
#   success      -> gate = now; the URL must be asked for afresh to come back at all
#   no capture   -> gate = now + RETRY_COOLDOWN; archive.org has spoken, leave it alone
#   local fault  -> gate = now; OUR disk failed, not the archive -- do not hide that for a month
COOLDOWN_OUTCOMES = frozenset({"not-archived", "bad-url"})


def _load(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save(path, state):
    tmp = path + ".tmp"
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(tmp, "w") as fh:
            json.dump(state, fh, indent=1, sort_keys=True)
        os.replace(tmp, path)
    except OSError:
        pass


def _record(state, url):
    """The state record for one URL, created on first sight.

    `gate` is the instant the last decision about this URL was taken (0 = never decided). `asks` is the
    trailing window of ask timestamps AFTER that gate -- the only ones eligibility may consider."""
    return state.setdefault(url, {"count": 0, "asks": [], "gate": 0})


def _prune(rec):
    """Drop asks the gate has invalidated and cap the trailing window. Idempotent."""
    gate = rec.get("gate", 0)
    asks = sorted(t for t in rec.get("asks", []) if t > gate)
    rec["asks"] = asks[-MAX_ASKS:]


def ingest(spool_dir, state_path):
    """Fold any journalled misses into the persistent request state. Returns (state, new_lines).

    The journal is RENAMED first and read from the rename: the proxy opens the path fresh for every
    append, so it simply starts a new file and nothing is lost or double-counted. A malformed line is
    skipped rather than aborting the batch -- this is a hint channel, not a ledger.

    An ask inside a URL's cooldown still raises `count` (it is real demand, and it will order the queue
    later) but is pruned from `asks`, so it can never shorten the window it arrived in."""
    state = _load(state_path)
    journal = os.path.join(spool_dir, MISS_JOURNAL)
    batch = journal + f".{int(time.time())}"
    try:
        os.rename(journal, batch)
    except OSError:
        return state, 0  # nothing journalled since last time
    seen = 0
    try:
        with open(batch, errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                    url, when = str(rec["url"]), int(rec["t"])
                except (ValueError, KeyError, TypeError):
                    continue
                seen += 1
                cur = _record(state, url)
                cur["count"] += 1
                cur["asks"].append(when)
                _prune(cur)
    except OSError:
        pass
    with contextlib.suppress(OSError):
        os.remove(batch)
    _save(state_path, state)
    return state, seen


def due(state, now=None):
    """The URLs worth crawling now, most-asked first.

    Eligible when the gate has passed AND there are at least MIN_REQUESTS asks after that gate spanning
    at least MIN_SPREAD. Because a cooldown prunes the asks taken during it, a URL whose 30 days have
    just elapsed is NOT automatically retried: it re-enters the queue only once two fresh asks, fifteen
    minutes apart, have landed on the far side of the gate."""
    now = int(time.time() if now is None else now)
    out = []
    for url, rec in state.items():
        if now < rec.get("gate", 0):
            continue  # still inside a cooldown -- archive.org already answered this one
        asks = sorted(t for t in rec.get("asks", []) if t > rec.get("gate", 0))
        if len(asks) < MIN_REQUESTS or asks[-1] - asks[0] < MIN_SPREAD:
            continue
        out.append((rec.get("count", 0), url))
    out.sort(reverse=True)  # more requests -> higher priority
    return [url for _count, url in out]


def mark_served(state, url, outcome, now=None):
    """Close the book on one attempt by moving the URL's gate.

    Every outcome clears the asks that earned this attempt, so nothing is serviced twice on the same
    demand. The only question an outcome answers is HOW LONG the URL is then left alone: an archive.org
    "no capture in the ceiling" verdict buys 30 days, everything else is eligible again as soon as two
    fresh asks arrive. `cannot-store` is pointedly NOT cooled down -- that is our own disk failing, and
    burying it for a month would turn a full corpus volume into a month of silence."""
    rec = state.get(url)
    if not rec:
        return
    now = int(time.time() if now is None else now)
    rec["gate"] = now + RETRY_COOLDOWN if outcome in COOLDOWN_OUTCOMES else now
    rec["outcome"] = outcome
    rec["attempts"] = rec.get("attempts", 0) + 1
    _prune(rec)


def save(state_path, state):
    _save(state_path, state)


# --- servicing: turning a request into a mirrored page ------------------------------------------
#
# This half needs the corpus model but NOT the crawl's internals, and the crawl already imports this
# module -- so what it does need (its per-site records, its resource mirror) is handed in rather than
# imported back, which keeps the dependency one-way and this module testable on its own.


class Servicer:
    """Mirrors one requested URL: the page (or asset) itself, plus every resource it references.

    Constructed by the crawl with everything it needs. A request for a page on a site we already carry
    is fetched with THAT site's era date and ceiling, so it lands exactly as the site's own pages do;
    a request for a host we do not crawl gets a throwaway record with the default ceiling -- a station
    asking for a post-2000 page does not by itself justify letting the corpus past the museum's era
    rule. If a host should be allowed past it, that is a deliberate decision and its name goes in
    era-vips.json."""

    DEFAULT_DATE = "19990101"  # the corpus's centre of gravity; the id_ redirect resolves from there

    def __init__(self, states_by_host, staging, res_seen, lock, budget, mirror_resource):
        self.states_by_host = states_by_host
        self.staging, self.res_seen, self.lock, self.budget = staging, res_seen, lock, budget
        self.mirror_resource = mirror_resource

    def _state_for(self, host):
        import era_crawl  # deferred: the crawl imports this module, so importing it at load would cycle

        known = self.states_by_host.get(era_crawl.core.bare(host))
        if known:
            return known
        return era_crawl._site_state({"host": host, "date": self.DEFAULT_DATE, "depth": 0, "max_pages": 1}, 200)

    def __call__(self, url):
        """Return a short outcome word for the log."""
        import era_press_core as core

        host = core.host_of(url)
        if not host:
            return "bad-url"
        st = self._state_for(host)
        if core._have(self.staging, host, core.store_rel(url, True)):
            return "already-had-it"
        got = core.fetch_page(url, st["date"], st["ceiling"])
        if not got:
            return "not-archived"
        _ts, page, body, discovered = got
        if not core._write(self.staging, host, core.store_rel(url, page), body):
            return "cannot-store"
        with self.lock:
            st["fetched"] += 1
            st["bytes"] += len(body)
            self.budget["written"] += len(body)
        for kind, res_ts, orig in discovered:
            if kind == "res":
                self.mirror_resource(orig, res_ts, self.staging, self.res_seen, st, self.lock, self.budget)
        return "mirrored"


def watch(spool_dir, state_path, interval, stop, service, log=print, halted=lambda: False):
    """Fold the miss journal in every `interval` seconds and service what is due, most-asked first.

    Runs for the whole life of its host process, sharing the same paced fetch layer, so a page a station
    wanted five minutes ago does not wait for a multi-hour crawl pass to end. Every error is caught: a
    hint channel must never take its host down with it."""
    while not stop.is_set():
        try:
            state, seen = ingest(spool_dir, state_path)
            queue = due(state)
            if queue or seen:
                log(f"--- REQUESTS ({SOURCE}): {len(queue)} URL(s) due, {seen} new miss(es) journalled")
            for url in queue:
                if stop.is_set() or halted():
                    break
                outcome = service(url)
                mark_served(state, url, outcome)
                # Persist per URL, not per batch. A cooldown that lives only in memory is lost if this
                # process dies mid-queue, and the next fold would re-ask archive.org for every URL it
                # had just refused -- which is the exact behaviour the cooldown exists to prevent.
                save(state_path, state)
                # The cooldown is the part an operator needs to SEE: a silent "not-archived" looks
                # identical to a URL nobody asked for, and that ambiguity is what hid this whole
                # mechanism being dead for three days.
                extra = f" (quiet for {RETRY_COOLDOWN // 86400}d)" if outcome in COOLDOWN_OUTCOMES else ""
                log(f"    request {outcome}{extra}: {url}")
        except (OSError, ValueError) as exc:
            log(f"ERROR requests: {exc}")
        stop.wait(interval)


# --- the demand channel as its own process -------------------------------------------------------


def cmd_requests(a):
    """Service station requests, and nothing else — the demand channel as its own long-lived process.

    WHY SEPARATE. This loop used to be a thread inside cmd_crawl, which made its lifetime the crawl's
    lifetime. But a corpus crawl is a FINITE job: it stops cleanly at the budget or when the site list is
    exhausted, exits 0, and stays stopped (Restart=on-failure does not cover success). Demand-servicing
    is the opposite — it must be listening whenever a station is browsing. Tying the two together meant
    that from the moment the last crawl finished, every miss the fleet produced went into a journal
    nobody read. So the watcher now runs under its own unit (retronet-requests.service) and the crawl
    runs with --no-requests.

    Startup is deliberately cheap: the Servicer only needs each site's era date and ceiling, so this
    builds site states with _site_state and SKIPS _reconstruct — the expensive per-site disk walk that
    rebuilds a crawl frontier we are never going to use here."""
    import era_crawl  # deferred: era_crawl imports this module, so a top-level import would cycle

    era_crawl.fetch.RATE["min_interval"] = a.min_interval
    os.umask(0o022)  # world-readable: CT 951's unprivileged proxy must read what this writes
    os.makedirs(a.staging, exist_ok=True)
    os.makedirs(a.requests_dir, exist_ok=True)
    os.makedirs(os.path.dirname(a.requests_state) or ".", exist_ok=True)
    cfg = era_crawl.load_sites(a.sites, getattr(a, "vips", None))
    era_crawl.era_index.INDEX_DIR = os.path.join(os.path.dirname(a.requests_state) or ".", "cdx")
    for s in cfg:
        era_crawl.era_index.register_site(s["host"], s.get("date", "19970101"), s.get("ceiling"))
    states = [era_crawl._site_state(s, a.max_mb) for s in cfg]
    states_by_host = {era_crawl.core.bare(st["host"]): st for st in states}
    res_seen, lock = set(), threading.Lock()
    # No global size budget here: this channel mirrors single pages a station actually asked for, which
    # is orders of magnitude below the crawl's 5 GB. "stop" stays False so `halted` never trips.
    budget = {"budget": 0, "base": 0, "written": 0, "fetches": 0, "stop": False}
    servicer = Servicer(states_by_host, a.staging, res_seen, lock, budget, era_crawl._mirror_resource_mt)
    era_crawl._log(
        a.log,
        f"=== requests service start: {len(states)} known sites, spool {a.requests_dir}, "
        f"every {a.requests_interval}s, {RETRY_COOLDOWN // 86400}d cooldown on a dead URL",
    )
    watch(
        a.requests_dir,
        a.requests_state,
        a.requests_interval,
        threading.Event(),  # never set: this process runs until systemd stops it
        servicer,
        log=lambda m: era_crawl._log(a.log, m),
    )
