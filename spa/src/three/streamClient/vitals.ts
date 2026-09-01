// ============================================================================
//  streamClient/vitals — continuous stream health as a TIME SERIES.
//  ---------------------------------------------------------------------------
//  WHY THIS EXISTS. Every number below was already being computed, once every
//  five seconds, and rendered into a 140-character string that went to
//  `clientlog.jsonl` — a sample, never a signal. `abr.ts` has been formatting
//  fps, bitrate, decode latency, loss and RTT into `formatStatsLine()` since
//  the day the ABR controller was written; nothing downstream could plot any
//  of it, alert on any of it, or compare two stations on it, because it was
//  prose. This module takes the same tick and emits the numbers AS NUMBERS.
//
//  IT IS NOT AN EVENT LANE. Stalls, decode errors, ABR downshifts and blocked
//  audio are discrete and already have one (`analytics/streamEvents.ts`). What
//  goes here is the CONTINUOUS level such an event would be a threshold on —
//  which is why `framesDropped` rides as a cumulative counter and "the stream
//  stalled" is not in this file at all.
//
//  IT IS NOT `analytics/metrics.ts`. That plane is buckets, by explicit policy,
//  and its whole contract is aggregates with no per-sample timestamp. A time
//  series is a different shape, not a finer setting of the same one.
// ============================================================================

import { clientSessionId } from '../clientDebug';

/** One sample's numbers. Keys are the store's column names verbatim
 *  (`scripts/serve/vitals_schema.py` CATALOGUE) — deliberately not prettier
 *  ones, so that a value can be traced from this file to a chart axis without
 *  a translation table in between. A key the server does not know is ignored
 *  there rather than refused, so this may ship a vital before a deploy. */
export type VitalSample = Record<string, number>;

interface Envelope {
  station: string;
  sessionId: string;
  build: string;
}

/**
 * THE SAMPLE INTERVAL — one second, and it is chosen from what makes the
 * SIGNAL good, not from a capacity budget.
 *
 * The events this series has to make visible are short. A freeze latches after
 * 250 ms without decoded output; an ABR downshift and its recovery both happen
 * inside the controller's own 3-second rolling window; an audio underrun is
 * instantaneous. At the 5 s cadence the log line uses, a downshift and the
 * recovery from it can BOTH fall between two samples and the series shows a
 * flat line through a visible fault. At 1 s every ABR window contains three
 * samples and no freeze episode can hide entirely between two.
 *
 * ONE SECOND IS ALSO THE NATURAL FLOOR, which is why it is not faster. Four of
 * the vitals in every row are the DAEMON's own view, and `transport/mod.rs`
 * emits those at exactly 1 Hz. Sampling faster would repeat half of each row
 * verbatim — more rows, no more information.
 */
const SAMPLE_MS = 1_000;
/** How often the queue is drained to the server. NOT the sample interval:
 *  20 samples ride one POST. Twenty seconds matches the analytics sink's
 *  cadence, which is the interval this codebase has already decided a
 *  background POST may cost a visitor. */
const FLUSH_MS = 20_000;
/** Queue ceiling. At 1 s that is ~10 minutes of a backgrounded tab, far beyond
 *  what any flush gap can legitimately accumulate; past it the OLDEST are
 *  dropped, because in a stream fault the newest samples describe the fault. */
const MAX_PENDING = 600;
/** Server-side body cap is 512 KiB (`vitals.BODY_MAX`); stop well under it. */
const MAX_BATCH_CHARS = 200_000;

let pending: Array<{ t: number; v: VitalSample }> = [];
let envelope: Envelope | null = null;
let lastSampleAt = 0;
let timer: ReturnType<typeof setTimeout> | null = null;
let hooked = false;

/** u32 microsecond difference, as a SIGNED millisecond number.
 *
 *  Both media stamp their capture time with the server's µs clock truncated to
 *  32 bits, so the counter wraps every 2^32 µs ≈ 71.6 minutes and a naive
 *  subtraction across a wrap reports ±71 minutes of skew. Interpreting the
 *  difference as a signed 32-bit quantity gives the right answer for any true
 *  skew under ±35.8 minutes, which is every skew that is not already a bug of
 *  a different kind. Exported for the test. */
export function skewMs(audioTsUs: number, videoTsUs: number): number {
  const d = ((audioTsUs - videoTsUs) | 0); // two's-complement wrap, in µs
  return d / 1000;
}

/**
 * Name the producer. Called once per stream session, before the first sample.
 *
 * `station` becomes the store's `station` column and, at the far end of the
 * pipeline, the OTLP `service.instance.id` — which is the single field that
 * makes each exhibit its OWN monitored entity rather than a label on one
 * blurred service. It is worth getting right: an empty station id here is a
 * sample that lands under "unknown" and merges with every other one.
 */
export function beginVitals(station: string, build: string): void {
  envelope = { station: station || 'unknown', sessionId: clientSessionId(), build: build || 'unknown' };
  lastSampleAt = 0;
}

/**
 * Is a sample due? The cadence lives HERE and not in `abr.ts` because it is a
 * property of the vitals lane, not of the ABR tick that happens to drive it —
 * the tick runs at ~100 ms and its own log line at 5 s, and neither of those
 * numbers should move because this one does. The sink is single-session by
 * construction (one `envelope`), so one module-level clock is the right shape;
 * `beginVitals` resets it so a new station starts sampling immediately.
 */
export function dueForVitals(now: number): boolean {
  if (!envelope || now - lastSampleAt < SAMPLE_MS) return false;
  lastSampleAt = now;
  return true;
}

/** Queue one sample. Cheap and unconditional; the caller has already been told
 *  by `dueForVitals` that one is owed, and must not be given a second reason
 *  to think about cost. */
export function recordVitals(v: VitalSample): void {
  if (!envelope) return;
  try {
    // A sample with nothing finite in it is not a sample. Filtering here and
    // not at the server keeps a dead client from spending a POST on nulls.
    const clean: VitalSample = {};
    for (const [k, n] of Object.entries(v)) {
      if (typeof n === 'number' && Number.isFinite(n)) clean[k] = Math.round(n * 1000) / 1000;
    }
    if (!Object.keys(clean).length) return;
    pending.push({ t: Date.now(), v: clean });
    if (pending.length > MAX_PENDING) pending.splice(0, pending.length - MAX_PENDING);
    ensureTimer();
    ensurePagehideFlush();
  } catch { /* telemetry must never break the app */ }
}

function ensureTimer(): void {
  if (timer != null || typeof setTimeout === 'undefined') return;
  timer = setTimeout(() => { timer = null; void flushVitals(); }, FLUSH_MS);
}

function ensurePagehideFlush(): void {
  if (hooked || typeof window === 'undefined') return;
  hooked = true;
  // THE SAMPLES THAT MATTER MOST ARE THE LAST ONES. A stream that degrades
  // until the visitor gives up and closes the tab takes its final minute with
  // it unless this fires — which is exactly the minute an investigation wants.
  const go = () => { void flushVitals(true); };
  window.addEventListener('pagehide', go);
  window.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') go(); });
}

/**
 * Ship the queue. Failures FOLD BACK into the queue rather than being dropped:
 * a stream fault and a network fault arrive together often enough that
 * discarding on error would systematically lose the worst sessions — the
 * survivorship bias that makes a health dashboard say everything is fine.
 * An HTTP REFUSAL (4xx) does drop, because re-offering a body the server has
 * already judged malformed is a loop.
 */
export async function flushVitals(final = false): Promise<void> {
  if (!envelope || !pending.length || typeof fetch === 'undefined') return;
  const batch = pending;
  pending = [];
  const body = JSON.stringify({
    resource: {
      'service.instance.id': envelope.station,
      'session.id': envelope.sessionId,
      'kh.bundle': envelope.build,
      'kh.source': 'spa',
    },
    samples: batch,
  });
  if (body.length > MAX_BATCH_CHARS) {
    // Over the wire budget. Keep the NEWEST half and drop the oldest — the
    // opposite of what a queue usually does, and right here for the same
    // reason MAX_PENDING drops from the front: in a stream fault the recent
    // samples describe the fault and the old ones describe the calm before
    // it. The kept half goes back for the next tick rather than being sent
    // now, so this path costs a flush interval and never a request that the
    // server would refuse.
    pending = batch.slice(Math.floor(batch.length / 2)).concat(pending).slice(-MAX_PENDING);
    return;
  }
  try {
    const res = await fetch('/vitals', {
      method: 'POST',
      // `keepalive` is what makes the pagehide flush actually leave the tab.
      keepalive: final,
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body,
    });
    if (!res.ok && res.status >= 500) pending = batch.concat(pending).slice(-MAX_PENDING);
  } catch {
    pending = batch.concat(pending).slice(-MAX_PENDING);
  }
}

/** Drop everything and forget the producer. Called when a stream session ends
 *  so the next one does not inherit the previous station's envelope. */
export function endVitals(): void {
  void flushVitals(true);
  envelope = null;
  if (timer != null) { clearTimeout(timer); timer = null; }
}
