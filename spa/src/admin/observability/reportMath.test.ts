// ============================================================================
//  reportMath tests — the numbers this dashboard will be quoted on.
//  ---------------------------------------------------------------------------
//  The percentile cases are ports of `ReachReportTest` in
//  scripts/test_analytics.py, deliberately with the same names and the same
//  fixtures: two implementations of one calculation over one store must be
//  wrong in the same way or not at all, and the cheapest way to keep that true
//  is to make the divergence show up as a failing test rather than as two
//  screens that disagree.
// ============================================================================

import { describe, expect, it } from 'vitest';
import type { AnalyticsReport, Catalogue } from './types';
import {
  dataState,
  errorRows,
  formatEdge,
  funnelRows,
  isProxyMetric,
  metricRows,
  pairRows,
  percentile,
  reachRows,
} from './reportMath';

function report(over: Partial<AnalyticsReport> = {}): AnalyticsReport {
  return {
    window: { days: 30, since: '2026-08-01', class: 'human' },
    lastAt: '2026-08-31T09:00:00Z',
    probes: {},
    flows: {},
    metrics: {},
    errors: [],
    ...over,
  };
}

const CATALOGUE: Catalogue = {
  probes: {
    'stream.stats.polled': {
      area: 'stream', owner: 'src/a.ts', what: 'stats were polled', grades: ['auto'],
    },
    'stream.overlay.shown': {
      area: 'stream', owner: 'src/b.tsx', what: 'the overlay was opened', grades: ['show', 'act'],
      consumes: 'stream.stats.polled',
    },
    'fleet.sorted': { area: 'fleet', owner: 'src/c.tsx', what: 'a human sorted', grades: ['act'] },
  },
  flows: {
    'station.connect': {
      area: 'station', what: 'opening a station', steps: ['open', 'transport', 'firstFrame'],
    },
  },
  metrics: {
    'station.open.toFirstFrameMs': {
      area: 'station', owner: 'src/d.ts', what: 'a high value means a spinner', scale: 'ms',
    },
    'poster.read.scrollReversals': {
      area: 'poster', owner: 'src/e.ts', what: 'a high value means re-reading', scale: 'count',
    },
  },
};

describe('percentile', () => {
  it('picks the bucket the sample lands in', () => {
    const buckets = { '50': 10, '100': 10, '200': 80 };
    expect(percentile(buckets, 0.5)).toEqual({ edge: '200', n: 100 });
    expect(percentile(buckets, 0.1)).toEqual({ edge: '50', n: 100 });
    expect(percentile(buckets, 0.95)).toEqual({ edge: '200', n: 100 });
  });

  it('sorts inf LAST so the tail is the tail', () => {
    // Sorted as text, "inf" lands between "100" and "50" and a p95 would read
    // as FASTER than a p50. That is the bug this asserts against, and it is the
    // one a reader would never question because the number looks like progress.
    const buckets = { inf: 5, '50': 95 };
    expect(percentile(buckets, 0.5)).toEqual({ edge: '50', n: 100 });
    expect(percentile(buckets, 0.99)).toEqual({ edge: 'inf', n: 100 });
  });

  it('sorts numerically, not lexically, across ladder decades', () => {
    // '1600' < '400' as text. A ms ladder crosses that boundary twice.
    const buckets = { '400': 10, '1600': 10, '12800': 80 };
    expect(percentile(buckets, 0.5).edge).toBe('12800');
    expect(percentile(buckets, 0.05).edge).toBe('400');
  });

  it('says an empty distribution is empty rather than guessing', () => {
    expect(percentile({}, 0.5)).toEqual({ edge: '-', n: 0 });
  });
});

describe('formatEdge', () => {
  it('uses the unit a reader thinks in', () => {
    expect(formatEdge('800', 'ms')).toBe('800ms');
    expect(formatEdge('3200', 'ms')).toBe('3.2s');
    expect(formatEdge('90', 'pct')).toBe('90%');
    expect(formatEdge('13', 'count')).toBe('13');
    expect(formatEdge('inf', 'ms')).toBe('over max');
    expect(formatEdge('-', 'ms')).toBe('-');
  });
});

describe('dataState', () => {
  it('tells a store that has never been posted to from a quiet window', () => {
    expect(dataState(report({ lastAt: null }))).toBe('no-store');
    expect(dataState(report())).toBe('empty-window');
    expect(dataState(report({ probes: { 'fleet.sorted': { act: 1 } } }))).toBe('ok');
  });
});

describe('reachRows', () => {
  it('is a LEFT JOIN: a probe nobody reached is a row reading zero', () => {
    const rows = reachRows(CATALOGUE, report({ probes: { 'fleet.sorted': { act: 4 } } }));
    expect(rows.map((r) => r.probe)).toEqual([
      'fleet.sorted', 'stream.overlay.shown', 'stream.stats.polled',
    ]);
    const never = rows.find((r) => r.probe === 'stream.overlay.shown');
    expect(never).toMatchObject({ auto: 0, show: 0, act: 0, total: 0, reached: false });
    expect(rows.find((r) => r.probe === 'fleet.sorted')).toMatchObject({ act: 4, reached: true });
  });

  it('totals every grade the store kept, not only the three columns', () => {
    // The store keeps what it was sent; a total built from auto+show+act alone
    // could read lower than the row it is summarising.
    const rows = reachRows(CATALOGUE, report({
      probes: { 'fleet.sorted': { act: 2, show: 1 } },
    }));
    expect(rows.find((r) => r.probe === 'fleet.sorted')?.total).toBe(3);
  });
});

describe('pairRows', () => {
  it('divides the consumer\'s show+act by the producer\'s auto count', () => {
    const rows = reachRows(CATALOGUE, report({
      probes: { 'stream.stats.polled': { auto: 388 }, 'stream.overlay.shown': { show: 0 } },
    }));
    expect(pairRows(rows)).toEqual([{
      producer: 'stream.stats.polled', consumer: 'stream.overlay.shown',
      calls: 388, used: 0, pct: 0,
    }]);
  });

  it('reports no ratio at all when the producer never ran', () => {
    // 0/0 is not 0%. "Used by nobody" and "not called either" are different
    // findings and only one of them is an argument for deleting anything.
    expect(pairRows(reachRows(CATALOGUE, report()))[0].pct).toBeNull();
  });
});

describe('funnelRows', () => {
  const flows = {
    'station.connect': {
      open: { enter: 388 },
      transport: { enter: 344, fail: 12 },
      firstFrame: { enter: 300, ok: 300 },
      nopasskey: { fail: 7 },
    },
  };

  it('counts down the DECLARED step order and shows where attempts die', () => {
    const [funnel] = funnelRows(CATALOGUE, report({ flows }));
    expect(funnel.steps.map((s) => [s.step, s.entered, s.lost])).toEqual([
      ['open', 388, 44],
      ['transport', 344, 44],
      ['firstFrame', 300, null],
    ]);
    expect(funnel.entered).toBe(388);
    expect(funnel.completed).toBe(300);
  });

  it('shows a fail reported ON a declared step, which the CLI drops', () => {
    const [funnel] = funnelRows(CATALOGUE, report({ flows }));
    expect(funnel.steps[1].failed).toBe(12);
  });

  it('breaks named fail reasons out separately, most frequent first', () => {
    const [funnel] = funnelRows(CATALOGUE, report({ flows }));
    expect(funnel.failReasons).toEqual([{ reason: 'nopasskey', n: 7 }]);
  });

  it('is a LEFT JOIN too: a flow nobody attempted is a funnel of zeros', () => {
    const [funnel] = funnelRows(CATALOGUE, report());
    expect(funnel.steps.map((s) => s.entered)).toEqual([0, 0, 0]);
    expect(funnel.what).toBe('opening a station');
  });
});

describe('metricRows', () => {
  it('is a LEFT JOIN and reports bucket edges, never an interpolated value', () => {
    const rows = metricRows(CATALOGUE, report({
      metrics: { 'station.open.toFirstFrameMs': { '800': 10, '3200': 10 } },
    }));
    const ms = rows.find((r) => r.metric === 'station.open.toFirstFrameMs');
    expect(ms).toMatchObject({ n: 20, scale: 'ms' });
    expect(formatEdge(ms!.p50.edge, 'ms')).toBe('800ms');
    expect(formatEdge(ms!.p95.edge, 'ms')).toBe('3.2s');
    const silent = rows.find((r) => r.metric === 'poster.read.scrollReversals');
    expect(silent).toMatchObject({ n: 0 });
    expect(silent!.p95.edge).toBe('-');
  });

  it('flags the behavioural proxies so the UI cannot imply they measure cognition', () => {
    expect(isProxyMetric('poster.read.scrollReversals')).toBe(true);
    expect(isProxyMetric('walkin.register.hesitationMs')).toBe(true);
    expect(isProxyMetric('keyboard.compose.correctionsPct')).toBe(true);
    expect(isProxyMetric('fleet.find.actionsToStation')).toBe(true);
    expect(isProxyMetric('station.open.toFirstInputMs')).toBe(true);
    // A stream/serving duration is a machine fact, not a proxy for effort.
    expect(isProxyMetric('station.open.toFirstFrameMs')).toBe(false);
    expect(isProxyMetric('walkin.play.queueMs')).toBe(false);
  });
});

describe('errorRows', () => {
  it('orders most frequent first and keeps the unattributed group', () => {
    const rows = errorRows(report({
      errors: [
        { fp: 'aaaa1111', flow: '', step: '', source: 'window', n: 3, message: 'boom' },
        { fp: 'bbbb2222', flow: 'station.connect', step: 'transport', source: 'react', n: 40, message: 'Failed to fetch' },
      ],
    }));
    expect(rows.map((r) => r.fp)).toEqual(['bbbb2222', 'aaaa1111']);
    expect(rows[1].flow).toBe('');
  });
});
