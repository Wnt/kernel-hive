"""Tail-based sampling for the VENDOR export — keep every error, every slow
action, and a random share of the rest.

WHAT THIS IS FOR, because a future reader will otherwise assume the wrong
thing and "optimise" it wrongly.

**It is not a capacity measure.** Our own store keeps EVERY action, on purpose:
one box, our own disk, our own data, and completeness beats cleverness when
nobody is short of capacity. What this protects is the VENDOR's Calls and
Services views, where routine traffic drowns the traffic worth looking at. The
operator has raised that twice. So the split is:

    SOURCE   (spa/src/three/streamClient/inputTrace.ts)
             every key and click edge is traced, in full, into traces.db.
    THIS FILE, at the Instana leg
             decide what Instana is shown.

WHY THE DECISION CAN LIVE HERE AT ALL, which is the whole architectural point.
Tail sampling normally needs a collector that buffers a complete trace before
deciding, and that is hard across processes — the browser cannot decide for
spans the daemon has not emitted yet, and the daemon cannot decide for the
browser's return leg. **We already have that collector: `traces.db`.** All
three producers land there, and the forwarder ALREADY waits for a trace to go
quiet before shipping it (`instana_backlog.QUIET_MS`, 210 s, sized so a
trace's daemon half has certainly arrived). That quiet window is exactly the
buffering a tail sampler needs; it simply was not making a keep/drop decision
yet. This adds the decision and no new machinery.

WHAT "KEEP" MEANS.

* **Every error.** Any span in the action with `status == "error"`. A failure is
  never sampled away — the whole reason to look at a trace is that something
  went wrong, and a 1-in-N failure record is worse than none because it reads
  as a rate.
* **Every slow one.** At or above `slow_ms`, derived below.
* **A random share of the rest**, `1 / RANDOM_KEEP_FACTOR`. RANDOM, not
  every-Nth: input is periodic (key auto-repeat, a held key, a drag), and a
  counter firing on every Nth trace can lock onto one PHASE of a repeat burst
  and sample the same recurring moment forever.

WHERE `slow_ms` COMES FROM, and why it is not a round number.

A fixed threshold cannot be right on this fleet. Measured on the live store,
`transport.frame.next` (guest injection -> frame on the wire, the dominant term
of the round trip) over 597 real samples: p50 = 43 ms, p75 = 113 ms,
p90 = 243 ms, p95 = 360 ms, p99 = 489 ms. That is an eleven-fold spread inside
ONE distribution, before accounting for the fact that a 1982 ZX Spectrum and a
w2kalpha share nothing. Any constant is right for one station and wrong for
sixty.

So the threshold is a ROLLING PERCENTILE of what this pipeline has actually
seen — `SLOW_PERCENTILE` over the last `WINDOW` completed actions — which
tracks the fleet as it changes and needs no maintenance.

It has a FLOOR, and the floor is the number that is derived rather than
chosen. Modelling the visitor-facing round trip from the same store's measured
parts at the 90th percentile:

    transport.frame.next   p90  243 ms   (n=597, daemon: injection -> wire)
  + client return leg      p90   23 ms   (n=27, receive + decode + paint)
  + kh.transport.rtt_ms    p90   13 ms   (n=49, application ping, same tab)
  --------------------------------------
    edge -> painted pixel  p90  279 ms

`SLOW_FLOOR_MS = 279`. It says: never call an action slow when nine actions in
ten on real traffic are already at least that slow. Without it, a fleet having
a good hour would push the rolling p95 down to a few tens of milliseconds and
this would start forwarding ordinary actions as "slow" — which is precisely
the noise the whole mechanism exists to remove.

While the window is still warming up (fewer than `MIN_WINDOW` samples) the
floor stands alone. FAIL OPEN, never closed: an action this module cannot yet
judge is FORWARDED, because a dropped trace cannot be recovered and a
duplicate one merely costs a row.

THE SAMPLING FACTOR. Instana's call detail reads `Sampling factor: 1` whatever
we do, and it under-reports accordingly. Whether an OTLP producer can DECLARE
its factor is **not documented**: the whole 326-file corpus at
`/home/wnt/instana-docs` never mentions "sampling factor", `sampling.factor`,
extrapolation, or an `x-instana-` header for it. The single adjacent hint is a
PHP-tracer release note (`0006-tracers-and-autotrace-webhook.md`) saying that
tracer "captures the OpenTelemetry TraceState sampling threshold value and
reports it to the backend" — implying an OTEP 235 `tracestate` `ot=th:` path
exists, documented for nobody else and contractually promised to no one. So
this stamps our OWN attributes and claims nothing about the vendor reading
them:

    kh.sampling.factor   how many actions this one stands for (1 when kept
                         for cause, RANDOM_KEEP_FACTOR when kept at random)
    kh.sampling.reason   error | slow | random

They are written onto the EXPORTED document only. `traces.db` never sees them:
it kept everything, so a sampling factor there would be a lie.

AND THE COUNTS DO NOT DEPEND ON ANY OF THIS. Every input edge already
increments the always-on counter plane — `three/usageStats.ts` tallies every
key and click per station to `/usage`, and the `station.key.used` /
`station.pointer.used` probes land in `analytics.db` — neither of which passes
through here. So "how many clicks happened" is an exact count from an
unsampled source, and this module only ever decides which of them Instana is
shown a flame graph FOR.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

#: Root span names this module makes a decision about. Everything else — a page
#: load, a `station.connect`, a `station.restore` — is rare, individually
#: interesting, and always forwarded.
ACTION_ROOTS = frozenset({"input.edge"})

#: Completed action durations kept for the rolling percentile. Small on purpose:
#: it is a threshold, not a dataset, and a short window tracks a fleet that
#: changes (a station promoted, a golden recaptured) instead of averaging over
#: its history.
WINDOW = 512
#: Below this many samples the percentile is not yet meaningful and the floor
#: stands alone.
MIN_WINDOW = 64
SLOW_PERCENTILE = 0.95
#: Derived from the live store, not chosen — see the module docstring.
SLOW_FLOOR_MS = 279
#: One in this many ordinary actions is forwarded, chosen by a coin.
RANDOM_KEEP_FACTOR = 10


def _root_of(trace: dict) -> dict | None:
    """The trace's root span. Since 2026-09-01 an action trace has exactly one
    (a trace means ONE ACTION), but a half-arrived trace legitimately has none
    yet, and this must never raise on one."""
    spans = trace.get("spans") or []
    ids = {s.get("spanId") for s in spans}
    roots = [s for s in spans if not s.get("parentId") or s.get("parentId") not in ids]
    if not roots:
        return None
    return min(roots, key=lambda s: s.get("startedMs", 0))


class TailSampler:
    """Keeps its rolling window beside the forwarder's own state file.

    Its own file rather than a key in the forwarder's state dict: that dict is
    the ingest WATERMARK, the one value whose corruption loses or replays data,
    and a sampling window has no business sharing its write path.
    """

    def __init__(self, state_path: Path, rng: random.Random | None = None):
        self.path = Path(state_path)
        self.rng = rng or random.Random()
        self.window: list[int] = []
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            got = raw.get("durations")
            if isinstance(got, list):
                self.window = [int(v) for v in got if isinstance(v, (int, float))][-WINDOW:]
        except Exception:
            # A missing or corrupt window is a cold start, never an error: the
            # floor stands alone until it refills.
            self.window = []

    def save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps({"durations": self.window[-WINDOW:]}), encoding="utf-8")
        except Exception:
            pass  # a threshold that cannot be persisted is a cold start, not a failure

    def slow_ms(self) -> int:
        """The current "slow" line: the rolling percentile, floored."""
        if len(self.window) < MIN_WINDOW:
            return SLOW_FLOOR_MS
        ordered = sorted(self.window)
        at = min(len(ordered) - 1, int(len(ordered) * SLOW_PERCENTILE))
        return max(SLOW_FLOOR_MS, ordered[at])

    def observe(self, dur_ms: int) -> None:
        self.window.append(int(dur_ms))
        if len(self.window) > WINDOW:
            del self.window[: len(self.window) - WINDOW]

    def decide(self, trace: dict) -> tuple[bool, str, int]:
        """`(keep, reason, factor)` for one complete trace.

        FAIL OPEN throughout. A trace this cannot classify — no root, an
        unfamiliar root name, a malformed duration — is forwarded, because a
        dropped trace is unrecoverable and a forwarded one costs a row.
        """
        root = _root_of(trace)
        if root is None or root.get("name") not in ACTION_ROOTS:
            return True, "not-an-action", 1

        if any(s.get("status") == "error" for s in trace.get("spans") or []):
            return True, "error", 1

        dur = root.get("durMs")
        if not isinstance(dur, int):
            return True, "unclassifiable", 1

        # Observed BEFORE the comparison, so the window describes the whole
        # population and not just the part that survived the last threshold —
        # a percentile fed only by its own keeps ratchets upward forever.
        threshold = self.slow_ms()
        self.observe(dur)
        if dur >= threshold:
            return True, "slow", 1

        if self.rng.random() < 1.0 / RANDOM_KEEP_FACTOR:
            return True, "random", RANDOM_KEEP_FACTOR
        return False, "dropped", 0


def apply(sampler: TailSampler, traces: list[dict]) -> tuple[list[dict], dict]:
    """Filter a chunk and stamp the survivors. Returns `(kept, counts)`.

    The stamp goes on the in-memory trace only. `traces.db` keeps every action
    and must never carry a sampling factor, which would be false about it.
    """
    kept: list[dict] = []
    counts = {"error": 0, "slow": 0, "random": 0, "dropped": 0, "passthrough": 0}
    for trace in traces:
        keep, reason, factor = sampler.decide(trace)
        if not keep:
            counts["dropped"] += 1
            continue
        if reason in counts:
            counts[reason] += 1
        else:
            counts["passthrough"] += 1
        if reason not in ("not-an-action", "unclassifiable"):
            for span in trace.get("spans") or []:
                attrs = span.setdefault("attributes", {})
                attrs["kh.sampling.factor"] = factor
                attrs["kh.sampling.reason"] = reason
        kept.append(trace)
    sampler.save()
    return kept, counts
