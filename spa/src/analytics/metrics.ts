// ============================================================================
//  analytics/metrics — how long it took, and how much effort it cost.
//  ---------------------------------------------------------------------------
//  The probe plane answers "did this run". This answers "was it any good".
//
//  THIS REVERSES A DECISION flows.ts used to state. That file said a flow is
//  not a span and nothing here measures time, on the grounds that latency
//  already has three better sources (the Ctrl+N overlay, clientlog's 5-second
//  stats line, the daemon's journal) and a fourth number would only disagree
//  with them. That reasoning was sound and about the wrong thing: all three of
//  those measure the STREAM — encoder, transport, decode. None of them
//  measures the VISITOR, and "how long from clicking a machine to seeing its
//  desktop" is not derivable from any of them, because it starts before the
//  stream exists and ends when a human's eyes are satisfied. So journey time
//  is measured here, stream time is not, and the boundary is: if the daemon
//  could answer it, this plane must not.
//
//  BUCKETS, NOT SAMPLES. A value is turned into a bucket in the TAB and only
//  the bucket travels. Three reasons, in order of importance:
//    1. A raw timing series is a behavioural trace of one person's session.
//       This plane is a durable aggregate kept for years (serve/analytics.py),
//       and a durable aggregate must not be where that lives.
//    2. p95 needs a distribution, and a mean is the statistic that hides
//       exactly the sessions worth fixing.
//    3. Volume: a bucketed metric costs one counter per bucket per day
//       however many samples land in it.
//  The cost is real and is stated rather than hidden: percentiles come out as
//  "p95 <= 3200 ms", never as a precise number the data cannot support.
//
//  THE CLOCK STOPS WHEN NOBODY IS LOOKING. A duration accumulates only the
//  time the document was VISIBLE. A connect that took four minutes because the
//  visitor backgrounded the tab for three of them is not a four-minute wait,
//  and a handful of those is enough to move a p95 into fiction. Metrics that
//  genuinely want away-time declare `countsHiddenTime` and are measured on the
//  wall clock instead — there is exactly one honest use of that (how long a
//  PWA session was away before it came back), and it is a quantity about the
//  visitor's absence rather than their patience.
//
//  MONOTONIC ONLY. `performance.now()`, never `Date.now()`: an NTP step or a
//  laptop suspend mid-timing would otherwise produce a negative duration or an
//  hour-long one, and both survive bucketing to poison the distribution.
// ============================================================================

import { METRICS, bucketFor, type MetricId } from './catalogue';
import { queueMetric } from './sink';
import { childOfActive, currentSpan, type Attrs } from './trace';

/** Values above this are refused outright rather than bucketed into `inf`.
 *  An hour of visible wait is not a slow connect, it is a bug in a call site
 *  that never stopped its timer, and letting it land would put a permanent
 *  fictional tail on a durable distribution. */
const SANE_MAX_MS = 3_600_000;

/** A running measurement. Stop it exactly once. */
export interface Timing {
  /** Record the elapsed time and close the timing. Later calls are ignored. */
  stop(): void;
  /** Abandon without recording — for a call site torn down rather than
   *  finished. Not a zero: a zero is a real, very fast sample, and inventing
   *  one per abandoned React effect would drag every p50 to the floor. */
  abandon(): void;
}

const NOOP_TIMING: Timing = { stop() {}, abandon() {} };

/** Every timing currently running, so one visibility change can pause them all
 *  without each call site knowing the tab exists. Bounded: a leaking call site
 *  costs a capped amount of memory and then stops being measured. */
const running = new Set<Live>();
const MAX_RUNNING = 64;

interface Live {
  id: MetricId;
  /** Visible milliseconds banked before the current visible span. */
  banked: number;
  /** `performance.now()` when the current visible span began, or null while
   *  the document is hidden. */
  since: number | null;
  /** Wall-clock start, for the `countsHiddenTime` metrics only. */
  wallStart: number;
  countsHidden: boolean;
}

let hooked = false;

function now(): number {
  try {
    return typeof performance !== 'undefined' ? performance.now() : Date.now();
  } catch {
    return Date.now();
  }
}

function visible(): boolean {
  try {
    return typeof document === 'undefined' || document.visibilityState !== 'hidden';
  } catch {
    return true;
  }
}

/** Pause/resume every running timing on a visibility change. Installed lazily
 *  so importing this module costs nothing until something is measured. */
function ensureHooked(): void {
  if (hooked || typeof document === 'undefined') return;
  hooked = true;
  try {
    document.addEventListener('visibilitychange', () => {
      const t = now();
      const nowVisible = visible();
      for (const live of running) {
        if (nowVisible) {
          if (live.since === null) live.since = t;
        } else if (live.since !== null) {
          live.banked += t - live.since;
          live.since = null;
        }
      }
    });
  } catch { /* no hook: durations then include hidden time, which we cannot fix */ }
}

/**
 * Put one finished measurement on the trace plane, as a point rather than a
 * shape.
 *
 * THE HOST IS RESOLVED AT STOP TIME, not at start, and that is the whole
 * subtlety. `currentSpan()` is guaranteed to be OPEN: every call site in this
 * codebase pops a span from the active stack BEFORE ending it (flows.ts's
 * `close`, navigation.ts's `finishNavigationSpan`, and this file), so a span
 * that is still active is a span that can still take an event. Resolving the
 * host at START time would instead hand us a span that may well have ended by
 * the time we stop — `Span.event()` after `end()` is a silent no-op, and the
 * number would vanish. Where the ordering matters the CALL SITE is what moves:
 * see `connectTelemetry.firstFrame`, which now stops its clock before it
 * closes its flow, precisely so the event lands on `station.connect`.
 *
 * WITH NO OPEN SPAN AROUND IT — a poster dwell, a hall navigation, an input
 * hesitation measured after its connect flow is legitimately over — the value
 * would otherwise never reach the trace plane at all, and this change is not
 * allowed to lose a number. Such a timing falls back to a ZERO-DURATION marker
 * span. That is not a relapse: it is not pushed active so it can never parent
 * real work, and its duration is 0 rather than the measurement, so no flame
 * graph can read it as elapsed effort. Those are exactly the two defects being
 * removed; a drillable row is what is left.
 */
function reportTiming(id: MetricId, ms: number, attrs?: Attrs): void {
  const host = currentSpan();
  if (host) return host.event(id, { 'kh.metric': id, 'kh.metric.ms': ms, ...attrs });
  const marker = childOfActive(id, { 'kh.metric': id, 'kh.metric.ms': ms, ...attrs });
  marker.end('ok');
}

/**
 * Begin measuring `id`. Always returns a handle; never throws.
 *
 * A MEASUREMENT IS NOT A SPAN. Until 2026-09-01 each timing opened a child
 * span named after the metric, made it the ACTIVE span, and let its wall
 * duration BE the value. All three of those were wrong, and the third was
 * only cosmetic:
 *
 *   1. `pushActive` made a measurement the PARENT of real work. In a captured
 *      operator trace (`fc4a9d74…`, win311) `station.open.toFirstFrameMs` was
 *      the parent of `http.client.request` -> `serve.signal`: the signaling
 *      fetch issued during the connect attached to whatever was active, and
 *      what was active was a clock. That is a false edge in the trace graph —
 *      it says the HTTP call happened *because of* the measurement — and it
 *      misattributes real server work under a synthetic node.
 *   2. The span's duration was the metric value, so a flame graph drew
 *      `station.open.toFirstInputMs` as 1.573 s of *work*. Nothing worked for
 *      1.573 s; that is the interval between two events, most of it a human
 *      deciding whether to touch the machine.
 *   3. One synthetic span per timing inflates span counts and lands in
 *      Instana's call and latency aggregates as a call that never happened.
 *
 * So a stopped timing now reports itself as an OTel SPAN EVENT — a timestamped
 * point carrying `kh.metric.ms` — on the innermost span that is genuinely open
 * around it. `station.connect` really does span the connect, so "first frame
 * painted at T, 260 ms after the attempt began" is a point inside it, which is
 * exactly what a span event is for. The event cannot parent anything and has
 * no duration to misread, and `_clean_events` (scripts/serve/traces.py) has
 * carried events end-to-end since the intake was written.
 *
 * NOTHING IS LOST. The bucketed sample still goes to the counter plane on
 * every stop, unchanged, which is the durable two-year answer. The exact value
 * still reaches the trace plane per session. What changed is where it hangs.
 *
 * `attrs` are repeated on the event (typically `stationAttrs(...)`) rather
 * than left to the host span, for the same reason `beginFlow` repeats them on
 * every step: a consumer reading the event in isolation must not have to walk
 * up to learn which station type it belongs to.
 */
export function startTiming(id: MetricId, attrs?: Attrs): Timing {
  try {
    const spec = METRICS[id] as { scale: string; countsHiddenTime?: boolean } | undefined;
    if (!spec || spec.scale !== 'ms') return NOOP_TIMING;
    if (running.size >= MAX_RUNNING) return NOOP_TIMING;
    ensureHooked();
    const live: Live = {
      id,
      banked: 0,
      since: visible() ? now() : null,
      wallStart: now(),
      countsHidden: spec.countsHiddenTime === true,
    };
    running.add(live);
    let done = false;
    return {
      stop() {
        try {
          if (done) return;
          done = true;
          running.delete(live);
          const elapsed = live.countsHidden
            ? now() - live.wallStart
            : live.banked + (live.since === null ? 0 : now() - live.since);
          recordMetric(id, elapsed);
          reportTiming(id, Math.round(elapsed), attrs);
        } catch { /* instrumentation never throws into the app */ }
      },
      abandon() {
        try {
          done = true;
          running.delete(live);
          // Nothing is reported at all — not a sample, not an event. An
          // abandoned timing is not a fast one and not a failed one (see the
          // Timing docblock), and the old code's `unset` span was a row in the
          // trace whose only content was that a React effect had unmounted.
        } catch { /* noop */ }
      },
    };
  } catch {
    return NOOP_TIMING;
  }
}

/**
 * Record one value directly — for the metrics that are not durations
 * (`count` and `pct` scales) and for a duration a call site timed itself.
 *
 * Negative and non-finite values are dropped rather than clamped to zero: a
 * negative duration means the caller's clock went backwards, and a zero is a
 * real observation that would quietly become the fastest sample in the set.
 */
export function recordMetric(id: MetricId, value: number): void {
  try {
    const spec = METRICS[id] as { scale: 'ms' | 'count' | 'pct' } | undefined;
    if (!spec) return;
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return;
    if (spec.scale === 'ms' && value > SANE_MAX_MS) return;
    queueMetric(id, bucketFor(spec.scale, value));
  } catch { /* never throw */ }
}

/**
 * An EFFORT accumulator: add as you go, report one total when the episode ends.
 *
 * The effort metrics — pixels scrolled sideways to find a column, corrections
 * per committed character, direction reversals while re-reading a paragraph —
 * are only meaningful as a per-EPISODE total. Reported per event they would
 * each be a distribution of ones and twos that says nothing, and reported as a
 * running sum they would double-count every partial.
 */
export function accumulator(id: MetricId): { add(n: number): void; commit(): void } {
  let total = 0;
  let closed = false;
  return {
    add(n: number) {
      if (closed || typeof n !== 'number' || !Number.isFinite(n) || n <= 0) return;
      total += n;
    },
    commit() {
      if (closed) return;
      closed = true;
      // A zero-effort episode IS a finding — it is the visitor who found what
      // they wanted without scrolling at all — so unlike an abandoned timing
      // it is recorded rather than dropped.
      recordMetric(id, total);
    },
  };
}

/** Test seam: forget every running timing and the visibility hook. */
export function __resetMetrics(): void {
  running.clear();
  hooked = false;
}
