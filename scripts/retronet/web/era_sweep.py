#!/usr/bin/env python3
"""era_absent -- what archive.org does not have, and which pages we have already swept.

The resource sweep re-checks every page on disk for images and scripts it is missing, and that pass is
load-bearing: resources used to be mirrored only on a FRESH page fetch, so any page stored during a
spell of failing fetches kept its missing images forever (www.sun.com had 4 of 15, www.ibm.com 10 of
24). But it had no memory. `res_seen` is per-run and in memory, so a resource the Wayback Machine
never captured was re-requested on every pass and every restart, for as long as the corpus exists.

Measured on 2026-08-24, on a restart with an UNCHANGED site list: ~970 requests to archive.org in
eleven minutes, with the corpus size not moving one byte. All of it re-asking for things already known
to be absent.

So this module remembers two things, both with the same 30-day horizon:

* **absent resources** -- a URL archive.org had no in-ceiling capture for. Not re-requested until the
  horizon passes. This is the same bargain the station-request queue strikes in era_requests: "no
  capture" is not an answer that changes week to week, and every retry is a request made of someone
  else's infrastructure for a thing we already know is not there.
* **swept pages** -- a page whose references have all been walked. Skipped entirely next pass unless
  the page itself changed on disk, which turns the sweep from O(whole corpus) every pass into O(what
  is new). The two horizons are deliberately THE SAME constant: when an absent resource becomes
  eligible again, the page that references it stops being skipped in the same cycle, so the retry
  actually happens.

The ledger is a plain JSON file beside state.json, pruned on load, and saved in batches -- it is a
cache, not a ledger of record. Losing it costs one expensive pass, never correctness.
"""

from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path

TTL = 30 * 24 * 3600  # how long "archive.org does not have this" is taken at its word
SAVE_EVERY = 250  # changes between batched writes; a crash costs at most this much memory


class Ledger:
    """Absent-resource and swept-page memory, safe for the crawl's 12-wide worker pool.

    Every method takes `now` so the whole thing is testable without waiting 30 days."""

    def __init__(self, path, ttl=TTL):
        self.path, self.ttl = path, ttl
        self._lock = threading.Lock()
        self._dirty = 0
        self.absent, self.swept = {}, {}
        self.load()

    # --- persistence ----------------------------------------------------------------------------
    def load(self, now=None):
        """Read the ledger, dropping anything already past its horizon. A missing or corrupt file is
        an EMPTY ledger, never an error: the cost of losing it is one slow pass."""
        now = int(time.time() if now is None else now)
        try:
            with open(self.path) as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        cut = now - self.ttl
        self.absent = {k: int(v) for k, v in (data.get("absent") or {}).items() if int(v) > cut}
        self.swept = {k: int(v) for k, v in (data.get("swept") or {}).items() if int(v) > cut}

    def save(self):
        """Atomic replace. Errors are swallowed -- a cache that cannot be written must not stop a crawl."""
        tmp = self.path + ".tmp"
        with self._lock:
            data = {"absent": dict(self.absent), "swept": dict(self.swept)}
            self._dirty = 0
        try:
            os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
            with open(tmp, "w") as fh:
                json.dump(data, fh, sort_keys=True)
            os.replace(tmp, self.path)
        except OSError:
            pass

    def _touch(self):
        """Called with the lock held. Batches writes so a wide pass is not one fsync per resource."""
        self._dirty += 1
        return self._dirty >= SAVE_EVERY

    # --- absent resources -----------------------------------------------------------------------
    def is_absent(self, url, now=None):
        """True if archive.org already told us it has no in-ceiling capture, recently enough to trust."""
        now = int(time.time() if now is None else now)
        with self._lock:
            seen = self.absent.get(url, 0)
        return seen > now - self.ttl

    def mark_absent(self, url, now=None):
        """Record a verdict from the ARCHIVE -- no capture, or none inside our era ceiling.

        Deliberately NOT called for a local failure (a filesystem namespace collision in _write): that
        is our bug to fix, and hiding it for a month would be the wrong trade."""
        now = int(time.time() if now is None else now)
        with self._lock:
            self.absent[url] = now
            flush = self._touch()
        if flush:
            self.save()

    # --- swept pages ----------------------------------------------------------------------------
    def needs_sweep(self, url, mtime, now=None):
        """True if this page must be walked: never swept, swept before it last changed, or past the horizon.

        Tying the skip to the page's own mtime is what keeps the sweep CORRECT while making it cheap --
        a page re-fetched with new markup is swept again immediately, not in thirty days."""
        now = int(time.time() if now is None else now)
        with self._lock:
            last = self.swept.get(url, 0)
        return not (last >= int(mtime) and last > now - self.ttl)

    def mark_swept(self, url, now=None):
        now = int(time.time() if now is None else now)
        with self._lock:
            self.swept[url] = now
            flush = self._touch()
        if flush:
            self.save()

    def stats(self):
        with self._lock:
            return {"absent": len(self.absent), "swept": len(self.swept)}


# --- the sweep itself -----------------------------------------------------------------------------
#
# It lives beside the memory it depends on, and takes its one crawl-side dependency (the threaded
# resource mirror) as an ARGUMENT rather than importing era_crawl back -- the same one-way trick
# era_requests.Servicer uses, and what keeps this module testable on its own.


def sweep_page(st, url, staging, res_seen, lock, budget, ledger, mirror_resource):
    """Re-scan ONE page already on disk and mirror every resource it references that is missing.

    Pages on disk are NOT in the frontier -- _reconstruct counts them as done -- so the ordinary crawl
    never revisits them, and any page stored during a spell of failing fetches keeps its missing images
    forever. www.sun.com had 4 of its 15 images and www.ibm.com 10 of 24 for exactly that reason. The
    sweep is the pass that repairs them: a body read and a stat per reference, and a request only for a
    resource genuinely absent.

    INCREMENTAL. A page whose references were all walked is skipped outright next pass -- the ledger
    remembers it, keyed on the page's own mtime, so a page re-fetched with new markup is swept again at
    once and only an UNCHANGED, already-walked page is skipped. That turns the sweep from O(whole
    corpus) every pass into O(what is new), and the skip costs one stat instead of a read, a parse and
    a stat per reference. The 30-day horizon is shared with the absent-resource memory on purpose: when
    a resource becomes worth re-asking for, the page referencing it stops being skipped in the same
    cycle, so the retry actually happens."""
    import era_press_core as core  # deferred: era_crawl imports this module, so a top-level import would cycle

    dest = core._have(staging, core.host_of(url), core.store_rel(url, True))
    if not dest:
        return
    if ledger is not None:
        try:
            mtime = os.path.getmtime(dest)
        except OSError:
            return
        if not ledger.needs_sweep(url, mtime):
            with lock:
                st["skipped"] += 1
            return
    try:
        body = Path(dest).read_bytes()
    except OSError:
        return
    if not core.is_html("", body):
        if ledger is not None:
            ledger.mark_swept(url)  # nothing to walk on a non-HTML page: never read it again either
        return
    for kind, res_ts, orig in core.discover(body, url, st["date"]):
        if kind == "res":
            mirror_resource(orig, res_ts, staging, res_seen, st, lock, budget)
    # Marked only after every reference has been handled, so an interrupted sweep re-walks the page.
    if ledger is not None:
        ledger.mark_swept(url)
