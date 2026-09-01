// ============================================================================
//  analytics/logSink — the browser's LOG lane, correlated to trace context.
//  ---------------------------------------------------------------------------
//  WHAT THIS REPLACES, AND WHY IT IS NOT A SECOND STORE. `/clientlog` has been
//  the only queryable record of what a tab did, and the only place in the whole
//  plane that holds a stack. It is also a flat JSONL file with no severity, no
//  trace id, a 36-hour window and no query surface but `grep`. This lane is its
//  successor, not its companion: it carries the same events as severity-bearing
//  log records into `logs.db`, where they join to the spans the same tab
//  already emits.
//
//  THE ONE THING THAT MAKES IT WORTH DOING is stamped at QUEUE time, not at
//  flush time: `currentSpan()` is read when the event happens, because by the
//  time a batch leaves (5 s later, or on pagehide) the span that caused it has
//  long since ended. A trace id resolved at flush time would correlate every
//  record in the batch to whatever happened to be open last, which is worse
//  than no correlation — it is a wrong answer that looks like a right one.
//
//  THE OVERLAP IS DELIBERATE AND TEMPORARY. While this ships, `/clientlog`
//  keeps writing too, so nothing is lost if this path has a defect; that costs
//  one extra POST per flush interval per tab. Its removal is a separate change
//  — see docs/lab/STREAM-DEBUGGING.md and the retirement gate in
//  docs/ANALYTICS.md.
//
//  NEVER THROWS. Same rule as every other sink here: telemetry that can break
//  the app is worse than no telemetry.
// ============================================================================

import { BUILD_ID } from './build';
import { currentSpan } from './trace';

/** Flush cadence, matched to /clientlog's so the two lanes stay comparable
 *  while both run. */
const FLUSH_MS = 5_000;
/** Under the store's 1 MiB body cap with room to spare; a batch this size is
 *  already far larger than an honest 5-second window. */
const MAX_BATCH_CHARS = 200_000;
/** Rows held between flushes. Oldest are dropped, so a long outage keeps the
 *  FRESHEST evidence — the same choice, for the same reason, clientDebug makes. */
const MAX_PENDING = 2_000;
const BODY_MAX = 8_000;

/** OTel severity text. The store maps these to SeverityNumbers. */
export type Severity = 'DEBUG' | 'INFO' | 'WARN' | 'ERROR';

/** One record on the wire. Compact keys: these travel from a phone on a radio,
 *  in a keepalive beacon, and the field names would otherwise be most of the
 *  body. Mirrors what `scripts/serve/logs.py::record` reads. */
interface WireLog {
  t: number;
  sv: Severity;
  b: string;
  tr?: string;
  sp?: string;
  a?: Record<string, string | number | boolean>;
}

/** Which client events are worth more than INFO. Everything absent is INFO.
 *
 *  This table is the ONLY judgement in this file, and it is what makes the lane
 *  usable: `severity >= WARN` has to mean "something went wrong for a visitor"
 *  or an operator learns to ignore it. The names are the event vocabulary
 *  clientlog already uses (three/connectTelemetry, stallWatch, recoverTelemetry,
 *  analytics/errors), so nothing here invents a new one. */
const SEVERITY_OF: Record<string, Severity> = {
  'client-error': 'ERROR',
  'unhandled-rejection': 'ERROR',
  'react-error': 'ERROR',
  'connect-giveup': 'ERROR',
  'no-video': 'ERROR',
  stall: 'WARN',
  'connect-retry': 'WARN',
  'connect-stalled': 'WARN',
  'recovery-reconnect': 'WARN',
  'sink-resumed': 'WARN',
  // The per-frame firehose. Kept at DEBUG rather than dropped: it is the raw
  // material of every stream investigation, and the store's severity filter is
  // a cheaper place to decide than a client-side allowlist nobody can change
  // without a deploy.
  stats: 'DEBUG',
  ptr: 'DEBUG',
  'drag-tel': 'DEBUG',
  'hover-tel': 'DEBUG',
};

let telemetryAllowed = false;
let pending: WireLog[] = [];
let flushTimer = 0;
let inFlight = false;
let session = 'unknown';
let hooked = false;

/** Enable the lane for this document, and tell it whose session this is. */
export function configureLogSink(opts: { allowed: boolean; sessionId: string }): void {
  telemetryAllowed = opts.allowed;
  session = opts.sessionId || 'unknown';
}

/** Queue one log record. `event` becomes the `kh.event` attribute and picks the
 *  severity; `detail` becomes the body. Extra attributes (a stack, a component
 *  stack, an href) ride `attrs` — this lane has no rule against a stack, which
 *  is precisely why clientlog.jsonl no longer has to exist to hold one. */
export function logRecord(
  event: string,
  detail: string,
  tile: string,
  attrs?: Record<string, string | number | boolean>,
): void {
  if (!telemetryAllowed) return;
  try {
    const rec: WireLog = {
      t: Date.now(),
      sv: SEVERITY_OF[event] ?? 'INFO',
      b: detail.length > BODY_MAX ? `${detail.slice(0, BODY_MAX - 1)}…` : detail,
      a: { 'kh.event': event, ...(tile ? { 'kh.station': tile } : {}), ...(attrs ?? {}) },
    };
    // The join, resolved NOW. See the header: at flush time this span is gone.
    const span = currentSpan();
    if (span) { rec.tr = span.traceId; rec.sp = span.spanId; }
    pending.push(rec);
    if (pending.length > MAX_PENDING) pending.splice(0, pending.length - MAX_PENDING);
    ensureTimer();
    ensurePagehide();
  } catch { /* telemetry must never break the app */ }
}

function ensureTimer(): void {
  if (flushTimer || typeof window === 'undefined') return;
  flushTimer = window.setInterval(() => flushLogs(), FLUSH_MS);
}

function ensurePagehide(): void {
  if (hooked || typeof window === 'undefined') return;
  hooked = true;
  try {
    // The last batch is the interesting one: a visit that ended badly is the
    // visit worth having. `visibilitychange` too, because iOS Safari can skip
    // `pagehide` entirely.
    window.addEventListener('pagehide', () => flushLogs(true));
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') flushLogs(true);
    });
    window.addEventListener('online', () => flushLogs());
  } catch { /* noop */ }
}

/** Send what is queued. `force` bypasses the single-flight guard, for teardown. */
export function flushLogs(force = false): void {
  try {
    if (!pending.length) return;
    if (inFlight && !force) return;
    let take = 0;
    let chars = 2;
    while (take < pending.length) {
      const n = JSON.stringify(pending[take]).length + 1;
      if (take > 0 && chars + n > MAX_BATCH_CHARS) break;
      chars += n;
      take++;
    }
    const batch = pending.slice(0, take);
    pending = pending.slice(take);
    const body = JSON.stringify({
      // The resource envelope, named once per batch rather than per record —
      // the same shape `/traces` takes, for the same reason.
      resource: {
        'service.name': 'kernel-hive-spa',
        'service.instance.id': session,
        'session.id': session,
        'kh.bundle': BUILD_ID,
      },
      logs: batch,
    });
    inFlight = true;
    void fetch('/logs', {
      method: 'POST',
      keepalive: true,
      headers: { 'Content-Type': 'application/json' },
      body,
    }).then((res) => {
      inFlight = false;
      // A NETWORK failure folds the batch back; an HTTP REFUSAL is a settled
      // answer and the batch is dropped. Re-queueing on a refusal is what turns
      // one lost record into an unbounded queue of them.
      if (!res.ok) return;
      if (pending.length) window.setTimeout(() => flushLogs(), 250);
    }).catch(() => {
      inFlight = false;
      pending = batch.concat(pending);
      if (pending.length > MAX_PENDING) pending.splice(0, pending.length - MAX_PENDING);
    });
  } catch { /* never throw */ }
}

/** Test seam. */
export function __resetLogSink(): void {
  pending = [];
  telemetryAllowed = false;
  inFlight = false;
  if (flushTimer && typeof window !== 'undefined') window.clearInterval(flushTimer);
  flushTimer = 0;
}

/** Test seam: what is queued but not yet sent. */
export function __pendingLogs(): readonly WireLog[] { return pending; }
