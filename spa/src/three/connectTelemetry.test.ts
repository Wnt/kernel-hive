// The connect ladder's telemetry, tested for the ONE property that its call
// order encodes and nothing else enforces: a stopped timing reports itself as
// a span EVENT on the innermost span still open (analytics/metrics.ts), so
// `firstFrame()` must stop its clock BEFORE it closes its flow. Get that
// backwards and there is no failure and no error — the flow root has already
// ended, `Span.event()` after `end()` is a silent no-op, and the number
// quietly relocates to a marker span outside the connect it describes.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import { connectTelemetry } from './connectTelemetry';
import { __resetFlows } from '../analytics/flows';
import { __resetMetrics } from '../analytics/metrics';
import { configureSink, __pendingBatch, __resetSink } from '../analytics/sink';
import { configureTracer, __bufferedSpans, __resetTracer } from '../analytics/trace';

beforeEach(() => {
  __resetFlows();
  __resetMetrics();
  __resetSink();
  __resetTracer();
  configureSink({ sessionId: 'test', allowed: true, clientClass: () => 'human' });
  configureTracer({ enabled: true, emit: () => {} });
});
afterEach(() => { __resetTracer(); __resetFlows(); });

describe('connect telemetry puts its measurements on the connect', () => {
  it('reports time-to-first-frame as an event on station.connect', () => {
    const t = connectTelemetry({ 'kh.station': 'win311' });
    t.transport();
    t.firstFrame();
    t.abandoned();

    const spans = __bufferedSpans();
    const root = spans.find((s) => s.n === 'station.connect')!;
    const ev = root.e!.find((e) => e.n === 'station.open.toFirstFrameMs');
    expect(ev).toBeTruthy();
    expect(typeof ev!.a!['kh.metric.ms']).toBe('number');
    // And the counter plane still has its bucketed sample.
    expect(__pendingBatch().metrics.some(
      (m) => m.id === 'station.open.toFirstFrameMs')).toBe(true);
  });

  it('emits no span named for a metric, and no metric parents a child', () => {
    const t = connectTelemetry();
    t.transport();
    t.firstFrame();
    t.firstInput();
    t.abandoned();

    const spans = __bufferedSpans();
    const metricNames = spans.filter((s) => s.n.endsWith('Ms')).map((s) => s.n);
    expect(metricNames).toContain('station.open.toFirstInputMs');
    // `toFirstInputMs` is measured after the connect flow has legitimately
    // closed, so it lands on a zero-duration marker rather than an event —
    // still a point, never a shape, and never a parent.
    for (const s of spans) {
      if (s.n.endsWith('Ms')) {
        expect(s.d).toBe(0);
        expect(spans.some((c) => c.p === s.s)).toBe(false);
      }
    }
    expect(metricNames).not.toContain('station.open.toFirstFrameMs');
  });
});
