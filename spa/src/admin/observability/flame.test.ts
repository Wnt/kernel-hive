// Layout tests. The rendering is eyeballed; THIS is the part that can be
// silently wrong, so every hazard the store can produce gets a case:
// out-of-order spans, a missing parent, a child escaping its parent, a parent
// cycle, a zero-duration span and hidden time. See flame.ts's header.
import { describe, it, expect } from 'vitest';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TraceDetail } from './TraceDetail';
import {
  MIN_ROW_WIDTH, buildFlameLayout, describeAnomaly, exceptionOf,
  formatDuration, hiddenShare, visibleMs,
} from './flame';
import type { TraceDetail as Trace, SpanEvent, TraceSpan } from './types';

let n = 0;
/** A span with only the fields a case cares about spelled out. */
function span(p: Partial<TraceSpan> = {}): TraceSpan {
  n += 1;
  return {
    spanId: String(n).padStart(16, '0'),
    parentId: null,
    name: 'span',
    kind: 'internal',
    startedMs: 1000,
    durMs: 100,
    hiddenMs: 0,
    status: 'unset',
    statusMessage: null,
    attributes: {},
    events: [],
    ...p,
  };
}

/** Rows keyed by span name — every case below asserts on names, not indexes,
 *  except where the ORDER is the thing under test. */
function named(spans: TraceSpan[]) {
  const layout = buildFlameLayout(spans);
  return { layout, at: (name: string) => layout.rows.find((r) => r.span.name === name)! };
}

describe('buildFlameLayout — the window', () => {
  it('is empty for no spans, and divides by nothing', () => {
    expect(buildFlameLayout([])).toEqual({
      rows: [], startMs: 0, endMs: 0, totalMs: 0, maxDepth: 0, anomalyCount: 0,
    });
  });

  it('spans earliest start to latest end, not the root span alone', () => {
    // The root ends first; a child outlives it. The window must still cover it,
    // or the child would be drawn off the end of the chart.
    const root = span({ name: 'root', startedMs: 1000, durMs: 50 });
    const kid = span({ name: 'kid', parentId: root.spanId, startedMs: 1010, durMs: 500 });
    const { layout } = named([root, kid]);
    expect(layout.startMs).toBe(1000);
    expect(layout.endMs).toBe(1510);
    expect(layout.totalMs).toBe(510);
  });

  it('places x and width as fractions of that window', () => {
    const root = span({ name: 'root', startedMs: 0, durMs: 1000 });
    const kid = span({ name: 'kid', parentId: root.spanId, startedMs: 250, durMs: 500 });
    const { at } = named([root, kid]);
    expect(at('root').x).toBeCloseTo(0);
    expect(at('root').width).toBeCloseTo(1);
    expect(at('kid').x).toBeCloseTo(0.25);
    expect(at('kid').width).toBeCloseTo(0.5);
  });

  it('keeps every bar inside the drawable area', () => {
    const rows = buildFlameLayout([
      span({ startedMs: 0, durMs: 1000 }),
      // A corrupt negative duration: treated as instant rather than drawn
      // backwards off the left edge.
      span({ startedMs: 400, durMs: -9999 }),
    ]).rows;
    for (const r of rows) {
      expect(r.x).toBeGreaterThanOrEqual(0);
      expect(r.x + r.width).toBeLessThanOrEqual(1.0000001);
    }
  });
});

describe('buildFlameLayout — the tree', () => {
  it('builds depth from parentId regardless of arrival order', () => {
    const a = span({ name: 'a', startedMs: 0, durMs: 900 });
    const b = span({ name: 'b', parentId: a.spanId, startedMs: 100, durMs: 500 });
    const c = span({ name: 'c', parentId: b.spanId, startedMs: 200, durMs: 100 });
    // Deepest first, root last — the order a late batch can produce.
    const { layout, at } = named([c, b, a]);
    expect(at('a').depth).toBe(0);
    expect(at('b').depth).toBe(1);
    expect(at('c').depth).toBe(2);
    expect(layout.maxDepth).toBe(2);
    expect(layout.rows.map((r) => r.span.name)).toEqual(['a', 'b', 'c']);
  });

  it('sorts siblings by start time so the graph reads left to right', () => {
    const root = span({ name: 'root', startedMs: 0, durMs: 1000 });
    const late = span({ name: 'late', parentId: root.spanId, startedMs: 700, durMs: 10 });
    const early = span({ name: 'early', parentId: root.spanId, startedMs: 100, durMs: 10 });
    const mid = span({ name: 'mid', parentId: root.spanId, startedMs: 400, durMs: 10 });
    const { layout } = named([late, early, mid, root]);
    expect(layout.rows.map((r) => r.span.name)).toEqual(['root', 'early', 'mid', 'late']);
  });

  it('emits several parentless spans as several roots', () => {
    const { layout } = named([
      span({ name: 'second', startedMs: 500, durMs: 10 }),
      span({ name: 'first', startedMs: 0, durMs: 10 }),
    ]);
    expect(layout.rows.map((r) => r.span.name)).toEqual(['first', 'second']);
    expect(layout.rows.every((r) => r.depth === 0)).toBe(true);
    expect(layout.anomalyCount).toBe(0);
  });
});

describe('buildFlameLayout — damage to the record', () => {
  it('never drops an orphan, and stands a synthetic parent up for it', () => {
    const orphan = span({ name: 'orphan', parentId: 'ffffffffffffffff', startedMs: 100, durMs: 200 });
    const { layout, at } = named([orphan]);
    expect(layout.rows).toHaveLength(2);
    const stand = layout.rows.find((r) => r.synthetic)!;
    expect(stand.span.name).toContain('missing parent');
    expect(stand.anomalies).toContain('synthetic');
    expect(stand.depth).toBe(0);
    // Inferred from the children that DID arrive, never measured.
    expect(stand.span.startedMs).toBe(100);
    expect(stand.span.durMs).toBe(200);
    expect(at('orphan').depth).toBe(1);
    expect(at('orphan').anomalies).toContain('orphan');
  });

  it('gives each missing parent its own stand-in, not one shared bucket', () => {
    // Which spans shared an unseen parent is information about what was lost.
    const { layout } = named([
      span({ name: 'a1', parentId: 'aaaaaaaaaaaaaaaa', startedMs: 0, durMs: 10 }),
      span({ name: 'a2', parentId: 'aaaaaaaaaaaaaaaa', startedMs: 20, durMs: 10 }),
      span({ name: 'b1', parentId: 'bbbbbbbbbbbbbbbb', startedMs: 40, durMs: 10 }),
    ]);
    expect(layout.rows.filter((r) => r.synthetic)).toHaveLength(2);
    expect(layout.rows).toHaveLength(5);
  });

  it('flags a child that starts before its parent WITHOUT moving the bar', () => {
    const root = span({ name: 'root', startedMs: 1000, durMs: 1000 });
    const kid = span({ name: 'kid', parentId: root.spanId, startedMs: 500, durMs: 200 });
    const { layout, at } = named([root, kid]);
    expect(at('kid').anomalies).toContain('starts-before-parent');
    // Drawn at its TRUE time: the window opens at 500, so the kid is at x=0.
    expect(at('kid').x).toBeCloseTo(0);
    expect(layout.startMs).toBe(500);
    expect(layout.anomalyCount).toBe(1);
  });

  it('flags a child that outlives its parent, and keeps its full width', () => {
    const root = span({ name: 'root', startedMs: 0, durMs: 100 });
    const kid = span({ name: 'kid', parentId: root.spanId, startedMs: 50, durMs: 950 });
    const { at } = named([root, kid]);
    expect(at('kid').anomalies).toContain('ends-after-parent');
    expect(at('kid').width).toBeCloseTo(0.95);
    expect(at('root').width).toBeCloseTo(0.1);
  });

  it('shows a parent cycle instead of losing it to an unreachable subtree', () => {
    // a→b→a: neither is a root, so a naive walk from the roots renders nothing.
    const a = span({ name: 'a', spanId: 'aaaaaaaaaaaaaaaa', parentId: 'bbbbbbbbbbbbbbbb', startedMs: 0, durMs: 10 });
    const b = span({ name: 'b', spanId: 'bbbbbbbbbbbbbbbb', parentId: 'aaaaaaaaaaaaaaaa', startedMs: 5, durMs: 10 });
    const { layout, at } = named([a, b]);
    expect(layout.rows).toHaveLength(2);
    expect(at('a').anomalies).toContain('cycle');
    expect(at('b').anomalies).toContain('cycle');
  });

  it('does not blow the stack on a deep chain', () => {
    // 2048 is the client's buffer cap; recursion here would take the page down.
    const spans: TraceSpan[] = [];
    let prev: string | null = null;
    for (let i = 0; i < 2048; i += 1) {
      const s = span({ name: `d${i}`, parentId: prev, startedMs: i, durMs: 1 });
      spans.push(s);
      prev = s.spanId;
    }
    const layout = buildFlameLayout(spans);
    expect(layout.rows).toHaveLength(2048);
    expect(layout.maxDepth).toBe(2047);
  });

  it('renders a duplicate span id once rather than twice', () => {
    const dup = span({ name: 'dup', spanId: 'cccccccccccccccc', startedMs: 0, durMs: 10 });
    expect(buildFlameLayout([dup, { ...dup, name: 'shadow' }]).rows).toHaveLength(1);
  });
});

describe('buildFlameLayout — an instant is not an absence', () => {
  it('gives a zero-duration span a visible minimum width', () => {
    const root = span({ name: 'root', startedMs: 0, durMs: 1000 });
    const tick = span({ name: 'tick', parentId: root.spanId, startedMs: 500, durMs: 0 });
    const { at } = named([root, tick]);
    expect(at('tick').width).toBe(MIN_ROW_WIDTH);
    expect(at('tick').x).toBeCloseTo(0.5);
  });

  it('survives a trace in which everything is instantaneous', () => {
    const { layout } = named([
      span({ name: 'a', startedMs: 7, durMs: 0 }),
      span({ name: 'b', startedMs: 7, durMs: 0 }),
    ]);
    expect(layout.totalMs).toBe(0);
    expect(layout.rows.every((r) => r.width === MIN_ROW_WIDTH)).toBe(true);
    expect(layout.rows.every((r) => Number.isFinite(r.x))).toBe(true);
  });
});

describe('hidden time — the number no other APM has', () => {
  it('measures the hidden slice against the bar as drawn', () => {
    const s = span({ name: 'connect', startedMs: 0, durMs: 240_000, hiddenMs: 230_000 });
    const { at } = named([s]);
    expect(at('connect').width).toBeCloseTo(1);
    expect(at('connect').hiddenWidth).toBeCloseTo(230 / 240, 3);
  });

  it('caps impossible hidden time and says so', () => {
    const { at } = named([span({ name: 'bad', startedMs: 0, durMs: 100, hiddenMs: 5000 })]);
    expect(at('bad').anomalies).toContain('hidden-exceeds-duration');
    expect(at('bad').hiddenWidth).toBeLessThanOrEqual(at('bad').width);
  });

  it('keeps a fully hidden instant fully hatched rather than rounding it away', () => {
    const { at } = named([span({ name: 'x', startedMs: 0, durMs: 0, hiddenMs: 3 })]);
    expect(at('x').hiddenWidth).toBe(at('x').width);
  });

  it('visibleMs is what the visitor actually sat through', () => {
    expect(visibleMs(span({ durMs: 240_000, hiddenMs: 230_000 }))).toBe(10_000);
    expect(visibleMs(span({ durMs: 100, hiddenMs: 900 }))).toBe(0);
    expect(hiddenShare(span({ durMs: 200, hiddenMs: 50 }))).toBeCloseTo(0.25);
    expect(hiddenShare(span({ durMs: 0, hiddenMs: 50 }))).toBe(0);
  });
});

describe('the read-out helpers', () => {
  it('formats a duration the way an operator scans a column', () => {
    expect(formatDuration(0)).toBe('0 ms');
    expect(formatDuration(940)).toBe('940 ms');
    expect(formatDuration(1500)).toBe('1.50 s');
    expect(formatDuration(45_000)).toBe('45.0 s');
    expect(formatDuration(230_000)).toBe('3m 50s');
    expect(formatDuration(-5)).toBe('0 ms');
  });

  it('pulls the OTel exception event out of a span', () => {
    const ev: SpanEvent = {
      n: 'exception',
      t: 5,
      a: { 'exception.type': 'TypeError', 'exception.message': 'x is not a function' },
    };
    const got = exceptionOf(span({ events: [{ n: 'other', t: 1 }, ev] }))!;
    expect(got).toEqual({ type: 'TypeError', message: 'x is not a function' });
    expect(exceptionOf(span({ events: [] }))).toBeNull();
    // An exception event whose attributes were stripped on intake still names
    // itself rather than rendering as blank.
    expect(exceptionOf(span({ events: [{ n: 'exception', t: 1 }] }))).toEqual({ type: 'Error', message: '' });
  });

  it('has a sentence for every anomaly it can raise', () => {
    const all = [
      'orphan', 'synthetic', 'cycle', 'starts-before-parent',
      'ends-after-parent', 'hidden-exceeds-duration',
    ] as const;
    for (const a of all) expect(describeAnomaly(a).length).toBeGreaterThan(20);
  });
});

// Render proof. The layout above is checked as data; this checks that the data
// actually reaches the screen — that an orphan really does draw a stand-in row,
// that an error really is a distinct bar, and that 1 span and 200 both come out
// as one row each. Static markup only: vitest runs under plain Node here (no
// jsdom, see vitest.config.ts), so this covers structure and not interaction.
describe('FlameGraph and TraceDetail render what the layout says', () => {
  it('renders a realistic trace', () => {
    const root = span({ name: 'station.connect', startedMs: 0, durMs: 240_000, hiddenMs: 230_000 });
    const kid = span({ name: 'signal.fetch', parentId: root.spanId, startedMs: 10, durMs: 40, kind: 'client', status: 'ok' });
    const bad = span({ name: 'transport.open', parentId: root.spanId, startedMs: 60, durMs: 0, status: 'error',
      attributes: { 'error.type': 'TypeError', station: 'beos' },
      events: [{ n: 'exception', t: 60, a: { 'exception.type': 'TypeError', 'exception.message': 'boom' } }] });
    const orphan = span({ name: 'lost.child', parentId: 'ffffffffffffffff', startedMs: 100, durMs: 20 });
    const trace: Trace = {
      traceId: 'a'.repeat(32), sessionId: 'sess-1', class: 'human', name: 'station.connect',
      startedMs: 0, durMs: 240_000, spanCount: 9, errorCount: 1, status: 'error',
      spans: [bad, orphan, root, kid],
    };
    const html = renderToStaticMarkup(createElement(TraceDetail, { trace, onSelectSession: () => {} }));
    expect(html).toContain('station.connect');
    expect(html).toContain('missing parent');
    expect(html).toContain('role="tree"');
    expect(html).toContain('fg-bar--error');
    expect(html).toContain('fg-hidden');
    expect(html).toContain('of 9 summarised');
    expect(html).toContain('96% hidden');
    expect(html).toContain('structurally broken');
    // 4 real spans + 1 synthetic stand-in
    expect((html.match(/role="treeitem"/g) ?? []).length).toBe(5);
  });
  it('renders a single-span trace and a 200-span trace', () => {
    for (const count of [1, 200]) {
      const spans = Array.from({ length: count }, (_, i) =>
        span({ name: `s${i}`, parentId: null, startedMs: i * 10, durMs: 5 }));
      const trace: Trace = { traceId: 'b'.repeat(32), sessionId: 's', class: 'probe', name: 's0',
        startedMs: 0, durMs: count * 10, spanCount: count, errorCount: 0, status: 'unset', spans };
      const html = renderToStaticMarkup(createElement(TraceDetail, { trace }));
      expect((html.match(/role="treeitem"/g) ?? []).length).toBe(count);
    }
  });
});
