"""POST /kh/deploy-hint — "something may have changed". Nothing more.

THE INVARIANT THAT MAKES A PUBLIC ENDPOINT ACCEPTABLE AT ALL:

    This endpoint cannot express WHAT to deploy. It can only say "look again".

It runs no git operation, spawns no process, reads no repository, and holds no
privilege that could deploy anything. Its entire side effect is bumping one
file's mtime. The reconciler (root) watches that file; this handler
(unprivileged, public) can only touch it. **The internet-facing half cannot
deploy, and the half that can deploy is not internet-facing.**

So the worst a forged, replayed or hostile signed request can achieve is one
extra `git fetch origin main` — and the rate limiter bounds even that. A payload
sha, if present, is recorded for the JOURNAL only; the reconciler verifies it is
an ancestor of the origin/main it fetched for itself, and a sha that is not an
ancestor is logged as an anomaly and changes nothing about what is deployed.

AUTHORISATION IS WRITE ACCESS TO THE REPO, AND NOTHING ELSE. Anyone who can push
to `main` can cause a deploy, because the push IS the deploy request. There is no
per-user auth and no allowlist: git already records who pushed. What this
authenticates is "this came from GitHub, for this repo", not "who pushed".

TWO KEYS, AND THE SOURCE IS WHICH KEY VERIFIED — never a field in the payload.
The webhook and the Actions ping carry different secrets, so "which trigger
fired" cannot be forged by whoever can reach the URL. That matters because the
whole backstop-visibility story in §1.1 rests on that signal being honest: if a
caller could claim `trigger=webhook`, "we have been running on the backstop"
would be exactly as invisible as it is today.

Checks run cheapest-and-most-rejecting first, and NOTHING does work before the
signature verifies.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import time
from collections import deque
from pathlib import Path

BODY_CAP = 2 * 1024 * 1024  # GitHub push payloads are large; the Actions ping is tiny
TIMESTAMP_WINDOW_S = 300
DEDUPE_MAX = 2048
DEDUPE_TTL_S = 3600
RATE_CAPACITY = 30
RATE_REFILL_PER_S = 0.5
WANTED_REF = "refs/heads/main"


def _infer_event(raw: bytes) -> str:
    """Event name from the payload shape, used only when the header is missing."""
    try:
        body = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return ""
    if not isinstance(body, dict):
        return ""
    if "zen" in body or "hook_id" in body:
        return "ping"
    return "push" if "ref" in body else ""


class Verdict:
    __slots__ = ("code", "source", "reason", "hint_sha")

    def __init__(self, code: int, reason: str, source: str | None = None, hint_sha: str | None = None):
        self.code = code
        self.reason = reason
        self.source = source
        self.hint_sha = hint_sha

    @property
    def accepted(self) -> bool:
        return self.code == 202

    def __repr__(self) -> str:
        return f"Verdict({self.code}, {self.reason!r}, source={self.source!r})"


class TokenBucket:
    """Counted BEFORE the HMAC, so signature verification cannot itself be the
    flood. A cheap check that gates an expensive one has to come first."""

    def __init__(self, capacity: int = RATE_CAPACITY, refill: float = RATE_REFILL_PER_S, now=time.monotonic):
        self.capacity = capacity
        self.refill = refill
        self.tokens = float(capacity)
        self.now = now
        self.last = now()

    def take(self) -> bool:
        current = self.now()
        self.tokens = min(self.capacity, self.tokens + (current - self.last) * self.refill)
        self.last = current
        if self.tokens < 1:
            return False
        self.tokens -= 1
        return True


class HintReceiver:
    """Pure verification. No I/O except the wakeup bump on an accepted hint."""

    def __init__(self, keys: dict[str, bytes], wakeup: Path | None = None, now=time.time, bucket=None):
        # keys: {"webhook": b"...", "actions": b"..."} — an EMPTY map means the
        # endpoint is not configured, and every request is refused. Unarmed by
        # default is the only safe default for a public deploy trigger.
        self.keys = {k: v for k, v in (keys or {}).items() if v}
        self.wakeup = Path(wakeup) if wakeup else None
        self.now = now
        self.bucket = bucket or TokenBucket()
        self._seen: deque[tuple[str, float]] = deque()
        self._seen_ids: set[str] = set()

    # ---- replay ---------------------------------------------------------
    def _remember(self, delivery: str) -> None:
        """Record an ACCEPTED delivery id, expiring old ones."""
        cutoff = self.now() - DEDUPE_TTL_S
        while self._seen and self._seen[0][1] < cutoff:
            old, _ = self._seen.popleft()
            self._seen_ids.discard(old)
        self._seen.append((delivery, self.now()))
        self._seen_ids.add(delivery)
        while len(self._seen) > DEDUPE_MAX:
            old, _ = self._seen.popleft()
            self._seen_ids.discard(old)

    # ---- signature ------------------------------------------------------
    def _source_of(self, raw: bytes, header: str) -> str | None:
        """Which configured key signed this body, by CONSTANT-TIME comparison."""
        if not header or not header.startswith("sha256="):
            return None
        offered = header[len("sha256=") :].strip()
        for name, secret in self.keys.items():
            expected = hmac.new(secret, raw, hashlib.sha256).hexdigest()
            if hmac.compare_digest(expected, offered):
                return name
        return None

    # ---- the whole decision ---------------------------------------------
    def verify(self, raw: bytes, headers: dict) -> Verdict:
        get = lambda k: headers.get(k) or headers.get(k.lower()) or ""  # noqa: E731
        if not self.keys:
            return Verdict(503, "no signing key configured; the endpoint is unarmed")
        if len(raw) > BODY_CAP:
            return Verdict(413, "body over cap")
        if not self.bucket.take():
            return Verdict(429, "rate limited")
        source = self._source_of(raw, get("X-Hub-Signature-256"))
        if source is None:
            # No detail, ever: a caller must not learn WHY it failed, and no
            # key material may reach a log.
            return Verdict(401, "bad signature")
        # THE EVENT HEADER MAY NOT SURVIVE THE HOP, AND THE DESIGN NEVER SAID IT
        # HAD TO. Measured 2026-08-31 on the first real delivery: the public edge
        # forwards `X-Hub-Signature-256` but drops `X-GitHub-*`, so every webhook
        # arrived as event "" and was answered 204 "ignoring event" — signature
        # verified, trigger silently dead. Identical requests scored 202 on the
        # LAN listener and 204 through the relay.
        #
        # Authorisation here is the HMAC over the BODY; the event header was only
        # ever a cheap pre-filter. So when it is absent, infer the event from the
        # payload shape — AFTER the signature has already passed, never before.
        # A ping payload carries `zen`/`hook_id` and no `ref`; a push carries
        # `ref`. Nothing about what gets deployed is decided here either way.
        event = get("X-GitHub-Event") or _infer_event(raw)
        if event == "ping":
            return Verdict(200, "ping acknowledged", source=source)
        if event != "push":
            return Verdict(204, f"ignoring event {event!r}", source=source)
        # Same hop problem: without X-GitHub-Delivery the dedupe would be off
        # entirely. A digest of the raw body is a sound substitute — GitHub's
        # push payloads differ per push (the sha alone guarantees it), so this
        # rejects a genuine replay while never colliding two real deliveries.
        delivery = get("X-GitHub-Delivery") or "body:" + hashlib.sha256(raw).hexdigest()[:32]
        if delivery and delivery in self._seen_ids:
            return Verdict(200, "duplicate delivery ignored", source=source)
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            # Dropped, never guessed at. A body we cannot parse cannot be shown
            # to name refs/heads/main, and this endpoint never assumes.
            return Verdict(400, "unparseable body", source=source)
        if not isinstance(body, dict):
            return Verdict(400, "unparseable body", source=source)
        if source == "actions":
            ts = body.get("ts")
            if not isinstance(ts, (int, float)) or abs(self.now() - ts) > TIMESTAMP_WINDOW_S:
                return Verdict(400, "stale or missing timestamp", source=source)
        ref = body.get("ref")
        if ref != WANTED_REF:
            return Verdict(204, f"ignoring ref {ref!r}", source=source)
        # The sha is a HINT for the journal. It never selects what is deployed.
        hint = body.get("after") if isinstance(body.get("after"), str) else None
        # ONLY an accepted delivery is remembered. GitHub redelivers a failed
        # delivery under the SAME id, so recording one we did not act on would
        # turn its own retry into a silent no-op — the endpoint would refuse the
        # redelivery of the push it had just dropped, and the box would sit
        # un-converged with both sides believing they had done their part.
        if delivery:
            self._remember(delivery)
        self._bump(source, hint)
        return Verdict(202, "wakeup enqueued", source=source, hint_sha=hint)

    def _bump(self, source: str, hint: str | None) -> None:
        """The entire side effect: rewrite ONE small file.

        It carries the trigger source because the backstop-visibility story in
        §1.1 depends on knowing WHICH trigger fired — and that must come from
        the key that verified, not from anything a caller could assert. The hint
        sha rides along for the journal only; the reconciler fetches
        origin/main itself and checks the hint is an ancestor of what it found.
        """
        if self.wakeup is None:
            return
        self.wakeup.parent.mkdir(parents=True, exist_ok=True)
        row = json.dumps({"source": source, "ts": self.now(), "hint": hint})
        tmp = self.wakeup.with_suffix(".tmp")
        tmp.write_text(row + "\n")
        os.replace(tmp, self.wakeup)


def handle_post(handler, receiver: HintReceiver) -> None:
    """HTTP shell. Reads the raw body (the signature covers the RAW bytes, so it
    must not be re-serialized), verifies, and replies with a bare status."""
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    raw = handler.rfile.read(min(length, BODY_CAP + 1)) if length > 0 else b""
    verdict = receiver.verify(raw, dict(handler.headers.items()))
    body = json.dumps({"status": verdict.reason})
    handler._send(verdict.code, body, "application/json", cache=False)
