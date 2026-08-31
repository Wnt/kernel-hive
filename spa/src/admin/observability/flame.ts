// ============================================================================
//  admin/observability/flame — turning a trace's spans into positioned rows.
//  ---------------------------------------------------------------------------
//  Pure layout, no React and no DOM, because this is the part that can be
//  WRONG in ways nobody notices. A flame graph that quietly drops a span is
//  worse than no flame graph at all: it reads as complete, so an operator
//  concludes the work it omitted never happened. Everything below therefore
//  errs towards rendering a span in the wrong-looking place over not rendering
//  it, and towards SAYING so when it does.
//
//  THE INPUT IS NOT A WELL-FORMED TREE AND CANNOT BE ASSUMED TO BE ONE.
//  scripts/serve/traces.py accepts spans of one trace across SEVERAL batches
//  (a journey outlives a 20 s flush) and rebuilds the summary from whatever has
//  arrived. So at any moment a trace may legitimately be missing a parent, have
//  several parentless spans, or have none at all. Clock skew is NOT among the
//  hazards — one tab, one clock — but batching, the 2048-span client buffer and
//  the MAX_SPANS_PER_BATCH cut are, and they produce the same shapes skew would.
//
//  WHAT IS CLAMPED AND WHAT IS ONLY FLAGGED, because the difference is the
//  whole honesty argument of this file:
//    * Geometry is clamped to the TRACE WINDOW. That is what keeps a bar inside
//      the drawable area, and since the window is by construction the union of
//      every span's extent it never actually moves a bar — it only defends
//      against a corrupt duration.
//    * A child escaping its PARENT is flagged, never clamped. On a chart whose
//      X axis is time, shrinking a bar to fit its parent would put it somewhere
//      it never ran, and it would no longer line up with the axis beside it —
//      falsifying the one thing the reader is measuring. The anomaly is real
//      data about a broken trace, so it is surfaced as a marker instead.
// ============================================================================

import type { TraceSpan } from './types';

/**
 * Something structurally wrong with the trace, kept per row so the UI can point
 * at it. These are not errors in the traced code — they are damage to the
 * RECORD of it, and confusing the two is how an operator ends up debugging a
 * bug that does not exist.
 */
export type RowAnomaly =
  /** `parentId` names a span this trace does not contain. */
  | 'orphan'
  /** Stands in for that missing parent; not a span anybody recorded. */
  | 'synthetic'
  /** Its parent chain loops, so it is reachable from no root. */
  | 'cycle'
  /** Starts before the parent it claims. */
  | 'starts-before-parent'
  /** Outlives the parent it claims. */
  | 'ends-after-parent'
  /** `hiddenMs > durMs`, which cannot be true; hidden time is shown capped. */
  | 'hidden-exceeds-duration';

/** One laid-out row. `x`/`width`/`hiddenWidth` are fractions of the trace
 *  window, so the component multiplies by whatever pixel width it has. */
export interface FlameRow {
  span: TraceSpan;
  /** 0 for a root. Drives indentation and `aria-level`, not the row's Y — see
   *  `buildFlameLayout` on why rows are one-per-span. */
  depth: number;
  /** Left edge, 0..1 of the trace window. */
  x: number;
  /** 0..1, never below `MIN_ROW_WIDTH` so an instant span still has a body. */
  width: number;
  /** How much of `width` was hidden. Right-anchored by the renderer because the
   *  store knows the AMOUNT of hidden time and not WHERE in the span it fell. */
  hiddenWidth: number;
  anomalies: RowAnomaly[];
  /** True for a stand-in row invented for a missing parent. */
  synthetic: boolean;
}

export interface FlameLayout {
  rows: FlameRow[];
  /** Trace window, recomputed from the spans present rather than taken from the
   *  summary row: `traces.py` rebuilds that summary as batches land, so mid
   *  flight it can describe a trace shorter than the spans already in hand. */
  startMs: number;
  endMs: number;
  totalMs: number;
  maxDepth: number;
  /** Rows carrying at least one anomaly — what the header warns about. */
  anomalyCount: number;
}

/** A zero-duration span must still be a target you can see and click. 0.4% of
 *  the width is a sliver at any sane size; the component also enforces a pixel
 *  floor in CSS, because 0.4% of a narrow panel is still nothing. */
export const MIN_ROW_WIDTH = 0.004;

const EMPTY: FlameLayout = { rows: [], startMs: 0, endMs: 0, totalMs: 0, maxDepth: 0, anomalyCount: 0 };

/** Left-to-right, then by id so a redraw never reshuffles equal starts. */
function byStart(a: TraceSpan, b: TraceSpan): number {
  return a.startedMs - b.startedMs || (a.spanId < b.spanId ? -1 : a.spanId > b.spanId ? 1 : 0);
}

/** Negative durations are not representable on a time axis; treat as instant.
 *  The store already refuses `d < 0` on intake, so this is belt and braces for
 *  a row written by an older schema. */
function endOf(s: TraceSpan): number {
  return s.startedMs + Math.max(0, s.durMs);
}

/** The stand-in for a parent that never arrived. Its extent is INFERRED from
 *  the children that did, which is why it is marked: an operator must not read
 *  a duration nobody measured as if it were observed. */
function syntheticParent(parentId: string, kids: TraceSpan[]): TraceSpan {
  const start = Math.min(...kids.map((k) => k.startedMs));
  const end = Math.max(...kids.map(endOf));
  return {
    spanId: parentId,
    parentId: null,
    name: `missing parent ${parentId.slice(0, 8)}`,
    kind: 'internal',
    startedMs: start,
    durMs: end - start,
    hiddenMs: 0,
    status: 'unset',
    statusMessage: null,
    attributes: {},
    events: [],
  };
}

/**
 * Lay a trace's spans out as rows.
 *
 * ONE ROW PER SPAN, not one band per depth. A true depth-banded flame graph
 * assumes siblings never overlap in time, and nothing in this pipeline
 * guarantees that — `childOfActive` nests by CALL ORDER rather than causality
 * (spa/src/analytics/trace.ts says so in its own header), so two genuinely
 * concurrent operations can land at the same depth over the same milliseconds
 * and draw on top of each other. Giving every span its own row costs vertical
 * space and buys the guarantee that no span can ever be hidden behind another;
 * `depth` still carries the nesting, as indentation and as `aria-level`.
 *
 * Order is depth-first pre-order over children sorted by start time, so the
 * list reads down the page in the order the work happened.
 */
export function buildFlameLayout(spans: readonly TraceSpan[]): FlameLayout {
  if (!spans.length) return EMPTY;

  const byId = new Map<string, TraceSpan>();
  for (const s of spans) if (!byId.has(s.spanId)) byId.set(s.spanId, s);

  const startMs = Math.min(...spans.map((s) => s.startedMs));
  const endMs = Math.max(...spans.map(endOf));
  const totalMs = endMs - startMs;
  // A trace whose spans are all instantaneous has no width to divide by. Every
  // row then min-widths to the same sliver, which is the truthful picture.
  const scale = totalMs > 0 ? totalMs : 1;

  const kids = new Map<string, TraceSpan[]>();
  const roots: TraceSpan[] = [];
  const orphanedBy = new Map<string, TraceSpan[]>();
  const push = (m: Map<string, TraceSpan[]>, k: string, v: TraceSpan) => {
    const list = m.get(k);
    if (list) list.push(v); else m.set(k, [v]);
  };
  for (const s of spans) {
    if (s.parentId === null) roots.push(s);
    else if (byId.has(s.parentId)) push(kids, s.parentId, s);
    else push(orphanedBy, s.parentId, s);
  }

  // Every missing parent gets its OWN stand-in rather than all orphans going
  // into one bucket. Which spans shared an unseen parent is real information
  // about what was lost, and merging them would destroy it.
  const orphanAnomalies = new Map<string, RowAnomaly[]>();
  for (const [parentId, list] of orphanedBy) {
    const stand = syntheticParent(parentId, list);
    byId.set(parentId, stand);
    kids.set(parentId, list);
    roots.push(stand);
    orphanAnomalies.set(parentId, ['synthetic']);
    for (const o of list) orphanAnomalies.set(o.spanId, ['orphan']);
  }

  const rows: FlameRow[] = [];
  const seen = new Set<string>();
  let maxDepth = 0;

  const emit = (span: TraceSpan, depth: number, extra: RowAnomaly[]): FlameRow => {
    const anomalies = [...extra];
    const parent = span.parentId === null ? null : byId.get(span.parentId) ?? null;
    if (parent) {
      if (span.startedMs < parent.startedMs) anomalies.push('starts-before-parent');
      if (endOf(span) > endOf(parent)) anomalies.push('ends-after-parent');
    }

    // Window clamp only — see the file header on why the parent is not a clamp.
    const left = Math.min(Math.max(span.startedMs, startMs), endMs);
    const right = Math.min(Math.max(endOf(span), left), endMs);
    let width = Math.max((right - left) / scale, MIN_ROW_WIDTH);
    if (width > 1) width = 1;
    const x = Math.min(Math.max((left - startMs) / scale, 0), 1 - width);

    const dur = Math.max(0, span.durMs);
    const hidden = Math.max(0, span.hiddenMs);
    if (hidden > dur) anomalies.push('hidden-exceeds-duration');
    // Proportional to the bar as DRAWN, so a min-widthed sliver that was wholly
    // hidden still reads as wholly hidden instead of as a rounding artefact.
    const hiddenWidth = dur > 0 ? width * Math.min(hidden / dur, 1) : hidden > 0 ? width : 0;

    const row: FlameRow = {
      span, depth, x, width, hiddenWidth, anomalies,
      synthetic: extra.includes('synthetic'),
    };
    if (depth > maxDepth) maxDepth = depth;
    rows.push(row);
    return row;
  };

  // Explicit stack, not recursion: a 2048-span buffer with a pathological chain
  // would be a stack overflow inside an admin page, and this must not be able
  // to take the page down.
  const stack: Array<{ span: TraceSpan; depth: number; extra: RowAnomaly[] }> = [];
  for (const r of [...roots].sort(byStart).reverse()) {
    stack.push({ span: r, depth: 0, extra: orphanAnomalies.get(r.spanId) ?? [] });
  }
  while (stack.length) {
    const { span, depth, extra } = stack.pop()!;
    if (seen.has(span.spanId)) continue;
    seen.add(span.spanId);
    emit(span, depth, extra);
    const children = kids.get(span.spanId);
    if (!children) continue;
    for (const c of [...children].sort(byStart).reverse()) {
      stack.push({ span: c, depth: depth + 1, extra: orphanAnomalies.get(c.spanId) ?? [] });
    }
  }

  // Anything the walk could not reach is in a parent CYCLE (a→b→a). Corrupt,
  // impossible from a correct client, and still shown: an unreachable span that
  // silently vanished would be indistinguishable from work that never ran.
  for (const s of spans.filter((s) => !seen.has(s.spanId)).sort(byStart)) {
    seen.add(s.spanId);
    emit(s, 0, ['cycle']);
  }

  return {
    rows, startMs, endMs, totalMs, maxDepth,
    anomalyCount: rows.filter((r) => r.anomalies.length > 0).length,
  };
}

/** Wall-clock time the visitor was actually looking at the page. THE number to
 *  judge a span by: a 4-minute span that was hidden for 3:50 is a 10-second
 *  span with a coffee break in it, and calling that slow sends somebody
 *  optimising code that was never on screen. */
export function visibleMs(span: TraceSpan): number {
  return Math.max(0, Math.max(0, span.durMs) - Math.max(0, span.hiddenMs));
}

/** Hidden fraction, 0..1, capped. */
export function hiddenShare(span: TraceSpan): number {
  const dur = Math.max(0, span.durMs);
  if (dur <= 0) return 0;
  return Math.min(Math.max(0, span.hiddenMs) / dur, 1);
}

/** Durations an operator reads at a glance. Sub-second stays in ms because
 *  "0.04 s" is harder to compare down a column than "40 ms". */
export function formatDuration(ms: number): string {
  const v = Math.max(0, ms);
  if (v < 1000) return `${Math.round(v)} ms`;
  if (v < 60_000) return `${(v / 1000).toFixed(v < 10_000 ? 2 : 1)} s`;
  const mins = Math.floor(v / 60_000);
  return `${mins}m ${Math.round((v - mins * 60_000) / 1000)}s`;
}

/** The `exception` event OTel's conventions define, if this span recorded one.
 *  `recordException` writes the status AND the event on purpose: the status is
 *  what makes a row red, the event is what carries the type and message. */
export function exceptionOf(span: TraceSpan): { type: string; message: string } | null {
  const ev = span.events.find((e) => e.n === 'exception');
  if (!ev) return null;
  const a = ev.a ?? {};
  return {
    type: String(a['exception.type'] ?? 'Error'),
    message: String(a['exception.message'] ?? ''),
  };
}

/** Human sentence for a structural fault, used in the row's tooltip, its
 *  `aria-label` and the detail pane — a coloured edge nobody can explain is
 *  noise, and this tool is read by whoever is on call, not by its author. */
export function describeAnomaly(a: RowAnomaly): string {
  switch (a) {
    case 'orphan':
      return 'Its parent span is not in this trace — the batch carrying it was dropped or has not landed yet.';
    case 'synthetic':
      return 'Placeholder for a parent span that never arrived. Its duration is inferred from its children, not measured.';
    case 'cycle':
      return 'Its parent chain loops, so it belongs under no root. Shown at the top level so it is not lost.';
    case 'starts-before-parent':
      return 'Starts before the parent it names. Batching, not clock skew — the bar is drawn at its true time.';
    case 'ends-after-parent':
      return 'Outlives the parent it names. Batching, not clock skew — the bar is drawn at its true time.';
    case 'hidden-exceeds-duration':
      return 'Reports more hidden time than it lasted; hidden time is shown capped at the span duration.';
  }
}
