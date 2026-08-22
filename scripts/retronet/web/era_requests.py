#!/usr/bin/env python3
"""era_requests -- what the retronet was ASKED for and could not answer.

A miss is the most honest signal this system produces. The disk scan that seeded
era-sites.json can only find URLs that happen to sit in a guest image as readable
text; it will always miss some, and it can never know which of them a visitor
actually walks to. A miss knows: a station asked, and the museum had nothing.

So the proxy journals every miss (`proxy.record_miss`) and this module turns that
journal into a priority queue the crawl services:

* **Asked twice, at least 15 minutes apart.** One request is noise -- a typo in the
  address bar, a probe, a broken image on a page nobody will revisit. Two requests
  separated by a real gap is a person or a station coming back to the same missing
  thing, which is exactly the signal worth acting on.
* **More requests, more priority.** The queue is ordered by how many times a URL
  has been asked for.
* **Serviced once per new demand.** After a URL is mirrored its request count is
  banked; it only becomes eligible again if it is asked for MORE times after that,
  which stops a genuinely unarchivable URL from being retried forever.

The journal lives at the corpus root -- the one path the gateway CT and the crawl
box share -- and is rotated before reading, so the proxy can keep appending to a
fresh file while a batch is processed. See docs/lab/retronet/ERA-PRESS.md.
"""

from __future__ import annotations

import contextlib
import json
import os
import time

MISS_JOURNAL = "_requests.jsonl"  # written by proxy.record_miss at the corpus root
MIN_REQUESTS = 2  # asked for at least this many times...
MIN_SPREAD = 15 * 60  # ...spanning at least this long, so a single burst is not enough
SOURCE = "station request"  # what these entries are, in the state file and the log


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


def ingest(corpus_root, state_path):
    """Fold any journalled misses into the persistent request state. Returns (state, new_lines).

    The journal is RENAMED first and read from the rename: the proxy opens the path fresh for every
    append, so it simply starts a new file and nothing is lost or double-counted. A malformed line is
    skipped rather than aborting the batch -- this is a hint channel, not a ledger."""
    state = _load(state_path)
    journal = os.path.join(corpus_root, MISS_JOURNAL)
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
                cur = state.setdefault(url, {"count": 0, "first": when, "last": when, "served": 0})
                cur["count"] += 1
                cur["first"] = min(cur["first"], when)
                cur["last"] = max(cur["last"], when)
    except OSError:
        pass
    with contextlib.suppress(OSError):
        os.remove(batch)
    _save(state_path, state)
    return state, seen


def due(state):
    """The URLs worth crawling now, most-asked first.

    Eligible when it has been asked for at least MIN_REQUESTS times, those requests span at least
    MIN_SPREAD, and there has been new demand since it was last serviced."""
    out = [
        (rec["count"], url)
        for url, rec in state.items()
        if rec.get("count", 0) >= MIN_REQUESTS
        and rec.get("last", 0) - rec.get("first", 0) >= MIN_SPREAD
        and rec.get("count", 0) > rec.get("served", 0)
    ]
    out.sort(reverse=True)  # more requests -> higher priority
    return [url for _count, url in out]


def mark_served(state, url):
    """Bank the current request count: this URL is eligible again only on NEW demand."""
    rec = state.get(url)
    if rec:
        rec["served"] = rec.get("count", 0)


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


def watch(staging, state_path, interval, stop, service, log=print, halted=lambda: False):
    """Fold the miss journal in every `interval` seconds and service what is due, most-asked first.

    Runs for the whole life of the crawl, alongside its passes and sharing the same paced fetch layer,
    so a page a station wanted five minutes ago does not wait for a multi-hour pass to end. Every error
    is caught: a hint channel must never take the crawl down with it."""
    while not stop.is_set():
        try:
            state, seen = ingest(staging, state_path)
            queue = due(state)
            if queue:
                log(f"--- REQUESTS ({SOURCE}): {len(queue)} URL(s) due, {seen} new miss(es) journalled")
            for url in queue:
                if stop.is_set() or halted():
                    break
                log(f"    request {service(url)}: {url}")
                mark_served(state, url)
            if queue:
                save(state_path, state)
        except (OSError, ValueError) as exc:
            log(f"ERROR requests: {exc}")
        stop.wait(interval)
