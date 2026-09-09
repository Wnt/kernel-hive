// ============================================================================
//  analytics/sink — the batch that leaves the tab.
//  ---------------------------------------------------------------------------
//  Three rules, each bought by something already in this repo:
//
//  1. COUNTS, NOT EVENTS. A probe hit is folded into a per-(id,grade) counter
//     and only the counters travel. A visitor hammering a guest produces one
//     row saying `station.key.used act 412`, not 412 rows. The gallery's own
//     usage plane learned this first (three/usageStats): a click is twenty
//     bytes of intent and a request per click is a request per click.
//
//  2. NEVER THROW, NEVER RETRY FOREVER. Every entry point is wrapped. A NETWORK
//     failure folds the batch back so a briefly-unreachable box costs a delay;
//     an HTTP REFUSAL is a settled answer and the batch is dropped. Re-queueing
//     on refusal is what would turn one lost tally into an unbounded queue of
//     them, and a signed-out tab at the walk-in door would do it every flush,
//     forever.
//
//  3. THE LAST BATCH IS THE INTERESTING ONE. A session that ends in a failed
//     flow is exactly the session worth having, so the queue flushes on
//     `pagehide` AND on `visibilitychange` to hidden (iOS Safari can skip
//     pagehide), with `keepalive` so it outlives the tab. sendBeacon cannot be
//     used: it omits the Origin header the public listener insists on.
//
//     `keepalive` ON THAT FLUSH AND NO OTHER — see `analytics/beacon.ts`. It
//     was on every flush until 2026-09-01, which spent the document's whole
//     64 KiB allowance within a couple of minutes and then silently killed
//     this route, `/traces`, `/clientlog` and `/logs` together for the rest of
//     the visit.
// ============================================================================

import type { ClientClass } from './intent';
import { flushSpans } from './trace';
import { postTelemetry } from './beacon';

/** Flush cadence. A session of a few minutes is a handful of requests. */
const FLUSH_MS = 20_000;
/** Hard ceiling on distinct rows held between flushes, so a runaway loop in a
 *  call site cannot grow the tab's memory. Far above any honest batch. */
const MAX_ROWS = 512;
/** Per-counter ceiling, mirroring what the server clamps to. Sending more is
 *  discarded server-side, so stop counting rather than lie. */
const MAX_COUNT = 100_000;

/** One aggregated probe counter, flattened for the wire. */
export interface ProbeRow { id: string; grade: string; n: number }
/** One flow observation. `outcome` is enter | ok | fail. */
export interface FlowRow { flow: string; step: string; outcome: string; n: number }
/** One metric bucket and how many samples landed in it this batch. */
export interface MetricRow { id: string; bucket: string; n: number }
/** One distinct error, with the count of how often it recurred this batch. */
export interface ErrorRow {
  fp: string;
  message: string;
  source: string;
  flow?: string;
  step?: string;
  n: number;
}

interface Batch {
  probes: Map<string, ProbeRow>;
  flows: Map<string, FlowRow>;
  metrics: Map<string, MetricRow>;
  errors: Map<string, ErrorRow>;
}

function emptyBatch(): Batch {
  return { probes: new Map(), flows: new Map(), metrics: new Map(), errors: new Map() };
}

let pending = emptyBatch();
let rows = 0;
let timer = 0;
let hooked = false;
let allowed = false;
let sessionId = '';
let classOf: () => ClientClass = () => 'unknown';

/** Wire up the sink. Until this is called nothing queues and nothing sends —
 *  the same shape as clientDebug's telemetry gate, and for the same reason: a
 *  signed-out stranger on the walk-in signup door has no session, so every
 *  flush would 401 and be re-queued forever. */
export function configureSink(opts: {
  sessionId: string;
  allowed: boolean;
  clientClass: () => ClientClass;
}): void {
  sessionId = opts.sessionId;
  allowed = opts.allowed;
  classOf = opts.clientClass;
  if (allowed) ensureTimer();
}

function bump<T extends { n: number }>(map: Map<string, T>, key: string, make: () => T): void {
  const cur = map.get(key);
  if (cur) {
    if (cur.n < MAX_COUNT) cur.n += 1;
    return;
  }
  if (rows >= MAX_ROWS) return;
  rows += 1;
  map.set(key, make());
  ensureTimer();
}

export function queueProbe(id: string, grade: string): void {
  if (!allowed) return;
  bump(pending.probes, `${id} ${grade}`, () => ({ id, grade, n: 1 }));
}

export function queueFlow(flow: string, step: string, outcome: string): void {
  if (!allowed) return;
  bump(pending.flows, `${flow} ${step} ${outcome}`, () => ({ flow, step, outcome, n: 1 }));
}

export function queueMetric(id: string, bucket: string): void {
  if (!allowed) return;
  bump(pending.metrics, `${id} ${bucket}`, () => ({ id, bucket, n: 1 }));
}

export function queueError(row: Omit<ErrorRow, 'n'>): void {
  if (!allowed) return;
  bump(pending.errors, row.fp, () => ({ ...row, n: 1 }));
}

function ensureTimer(): void {
  if (typeof window === 'undefined') return;
  if (!hooked) {
    hooked = true;
    try {
      window.addEventListener('pagehide', () => flushAnalytics(true));
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') flushAnalytics(true);
      });
    } catch { /* no lifecycle hooks: the interval is still the common path */ }
  }
  if (!timer) timer = window.setInterval(() => flushAnalytics(false), FLUSH_MS);
}

/** Send what has been counted. Driven by this module's own interval and its
 *  pagehide/visibilitychange hooks — no caller outside needs it, and a public
 *  flush would only invite a call site to try to make a batch "land now",
 *  which `keepalive` already guarantees for the case that matters. */
function flushAnalytics(final = false): void {
  try {
    if (!allowed) return;
    // Spans first, and unconditionally: they have their own buffer and their
    // own endpoint, and a batch with no COUNTERS in it can still be carrying a
    // whole trace. Gating them behind `rows` would have silently dropped the
    // traces of the quietest sessions — which, for a drilldown tool, are
    // exactly the ones somebody is hunting for.
    flushSpans(final);
    if (!rows) return;
    const batch = pending;
    pending = emptyBatch();
    rows = 0;
    const body = JSON.stringify({
      sessionId,
      class: classOf(),
      probes: [...batch.probes.values()],
      flows: [...batch.flows.values()],
      metrics: [...batch.metrics.values()],
      errors: [...batch.errors.values()],
    });
    // NO `traceparent`. `/analytics` is an excluded telemetry path: it opens
    // no client span, so there is no span for a header to name, and naming the
    // ambient one instead is exactly what left `serve.analytics` rootless
    // (khFetch.ts's `outboundTraceparent`). The server roots its own trace.
    void postTelemetry('/analytics', body, { final }).then((result) => {
      if (result === 'failed') foldBack(batch);
    });
  } catch { /* analytics must never break the app it measures */ }
}

/** A network failure keeps the evidence; an HTTP refusal does not. */
function foldBack(batch: Batch): void {
  for (const [k, v] of batch.probes) mergeRow(pending.probes, k, v);
  for (const [k, v] of batch.flows) mergeRow(pending.flows, k, v);
  for (const [k, v] of batch.metrics) mergeRow(pending.metrics, k, v);
  for (const [k, v] of batch.errors) mergeRow(pending.errors, k, v);
}

function mergeRow<T extends { n: number }>(map: Map<string, T>, key: string, row: T): void {
  const cur = map.get(key);
  if (cur) {
    cur.n = Math.min(MAX_COUNT, cur.n + row.n);
    return;
  }
  if (rows >= MAX_ROWS) return;
  rows += 1;
  map.set(key, row);
}

/** Test seam: what is counted but not yet sent. */
export function __pendingBatch(): {
  probes: ProbeRow[]; flows: FlowRow[]; metrics: MetricRow[]; errors: ErrorRow[];
} {
  return {
    probes: [...pending.probes.values()],
    flows: [...pending.flows.values()],
    metrics: [...pending.metrics.values()],
    errors: [...pending.errors.values()],
  };
}

/** Test seam: start from nothing, timer and gate included. */
export function __resetSink(): void {
  pending = emptyBatch();
  rows = 0;
  allowed = false;
  sessionId = '';
  if (timer && typeof window !== 'undefined') window.clearInterval(timer);
  timer = 0;
  hooked = false;
}
