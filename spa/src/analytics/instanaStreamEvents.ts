// ============================================================================
//  analytics/instanaStreamEvents — the Instana MIRROR. Thin, isolated, and
//  built to be deleted.
//  ---------------------------------------------------------------------------
//  OUR PLANE IS THE PRODUCT. Instana is a temporary benchmark the operator
//  intends to drop, so the direction of dependency is fixed and one-way:
//  `streamEvents.ts` decides what an event IS, what it carries and whether it
//  is sampled; this file only TRANSLATES a decision already made into the one
//  vendor call shape that can carry it. There is no policy here — no sampling,
//  no naming, no defaulting, no enrichment, no "while we're here" extras.
//  Deleting this file and its single call site removes Instana from the stream
//  plane entirely and changes nothing about what our own store receives.
//
//  WHAT THE VENDOR ACCEPTS, and the three rules that are easy to get wrong:
//
//    * `backendTraceId` must be EXACTLY 16 or 32 hex characters. The minified
//      agent validates it and SILENTLY DROPS THE FIELD otherwise — the docs
//      state no such rule at all; this was established by reading the real
//      bundle; `analytics/instana.ts` owns that rule and this module
//      re-exports it. Unlike `inputTrace`,
//      which abandons the whole call when the id is unusable BECAUSE the join
//      is the entire point of that beacon, a stream event is worth reporting
//      with or without a backend join — so a malformed id drops the FIELD and
//      the event still goes.
//    * `meta` values are STRINGS, and the vendor's own `maxMetadataKeys`
//      default is 25. Numbers and booleans are coerced here rather than at the
//      call site, because coercing at the call site is how our own span
//      attributes would have silently become strings too.
//    * `customMetric` is ONE number, kept to 4-decimal precision by the
//      vendor. One event, one number: whichever number the taxonomy declares
//      as that event's metric. Anything else that happens to be numeric stays
//      in `meta` as a string, where it is exact.
//
//  NO SYNTHETIC ENTRY SPANS. A rejected design asked for invented entry spans
//  so Instana's UI would render something more like a trace. That is not done
//  here and must not be added: it would make our plane's data a function of a
//  third party's rendering, which is the exact coupling this file exists to
//  avoid.
// ============================================================================

import { BACKEND_TRACE_ID_RE } from './instana';

/** The subset of `ineum` this module calls. Declared locally — see the header:
 *  this file must be deletable without touching anything else. */
declare global {
  interface Window {
    ineum?: (...args: unknown[]) => void;
  }
}

/**
 * Exactly what the vendor bundle accepts for `backendTraceId`.
 *
 * Re-exported from `./instana`, which is the single home for facts about the
 * vendor bundle. It briefly lived in `three/streamClient/inputTrace.ts` and was
 * copied here because `analytics/` must not depend on `three/`; that reason is
 * gone now that the canonical copy is this module's neighbour, so the copy is
 * too. One definition cannot drift from itself.
 */
export { BACKEND_TRACE_ID_RE };

/** The vendor's own `maxMetadataKeys` default. Enforced here rather than
 *  trusted to stay true by inspection. */
export const META_MAX_KEYS = 25;

/** One event, already decided by our own plane. */
export interface InstanaStreamEvent {
  /** The event name — our vocabulary, unchanged. */
  name: string;
  /** ms since epoch. */
  timestamp: number;
  /** Our own 32-hex trace id, or '' when tracing is off (NOOP span). */
  backendTraceId: string;
  /** Our span attributes. Coerced to strings here, capped here. */
  meta: Record<string, string | number | boolean>;
  /** The ONE number this event declares. Omitted when the event has none. */
  customMetric?: number;
}

function ineum(...args: unknown[]): void {
  try {
    if (typeof window === 'undefined') return;
    const fn = window.ineum;
    if (typeof fn === 'function') fn(...args);
  } catch {
    /* never throw: the vendor is a benchmark, never a dependency */
  }
}

/** 4 decimals, which is all `customMetric` keeps. Non-finite values are
 *  dropped rather than coerced to zero — a zero is a real observation and
 *  inventing one would put a fictional sample in the vendor's own chart. */
function metricValue(n: number | undefined): number | undefined {
  if (typeof n !== 'number' || !Number.isFinite(n)) return undefined;
  return Math.round(n * 10_000) / 10_000;
}

/** Strings only, at most `META_MAX_KEYS`. Insertion order is the call site's,
 *  so the taxonomy's own attributes survive a cap before the page binding's
 *  do — see `streamEvents.ts` for why that ordering is deliberate. */
function meta(raw: Record<string, string | number | boolean>): Record<string, string> {
  const out: Record<string, string> = {};
  let n = 0;
  for (const [k, v] of Object.entries(raw)) {
    if (n >= META_MAX_KEYS) break;
    out[k] = String(v);
    n += 1;
  }
  return out;
}

/**
 * Mirror one already-decided event to Instana. A no-op, silently, on an
 * unconfigured build (`window.ineum` absent — the vendor script never loaded)
 * and outside a browser.
 *
 * Never called for an event our own plane sampled away: the sampling decision
 * is made once, upstream, so the two systems see the same population and a
 * rate measured in one is a rate in the other.
 */
export function mirrorStreamEventToInstana(event: InstanaStreamEvent): void {
  try {
    if (typeof window === 'undefined' || typeof window.ineum !== 'function') return;
    const metric = metricValue(event.customMetric);
    ineum('reportEvent', event.name, {
      timestamp: event.timestamp,
      // Only when the vendor would actually keep it. A malformed id costs the
      // JOIN, never the event — see the header.
      ...(BACKEND_TRACE_ID_RE.test(event.backendTraceId)
        ? { backendTraceId: event.backendTraceId }
        : {}),
      meta: meta(event.meta),
      ...(metric === undefined ? {} : { customMetric: metric }),
      maxMetadataKeys: META_MAX_KEYS,
    });
  } catch {
    /* never throw */
  }
}
